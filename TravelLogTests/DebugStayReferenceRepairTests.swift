//
//  DebugStayReferenceRepairTests.swift
//  TravelLogTests
//
//  Pins for the DEBUG-only dangling ping-reference repair
//  (`DebugStayReferenceRepair`): the manual escape hatch for host stays
//  damaged by pre-2026-07-25 discards, which today's fail-closed discard
//  preflight refuses to work around automatically.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
struct DebugStayReferenceRepairTests {

    private static let base = Date(timeIntervalSinceReferenceDate: 457 * 86_400)
    private func d(_ days: Double) -> Date { Self.base.addingTimeInterval(days * 86_400) }

    private let athens = (lat: 37.9838, lon: 23.7275)

    @discardableResult
    private func makePing(
        in ctx: ModelContext,
        source: DataSource,
        at day: Double,
        latitude: Double? = nil
    ) -> LocationPing {
        let ping = LocationPing(
            timestamp: d(day),
            latitude: latitude ?? athens.lat,
            longitude: athens.lon,
            horizontalAccuracy: 30, h3IndexRes6: "8a2a1072b59ffff", source: source
        )
        ping.isProcessed = true
        ctx.insert(ping)
        return ping
    }

    @discardableResult
    private func makeStay(
        in ctx: ModelContext, source: DataSource, startDay: Double,
        endDay: Double, pingIDs: [UUID]
    ) -> Stay {
        let stay = Stay(
            startTime: d(startDay), endTime: d(endDay),
            centroidLatitude: athens.lat, centroidLongitude: athens.lon,
            h3IndexRes6: "8a2a1072b59ffff", pingCount: max(1, pingIDs.count),
            distanceFromHomeKm: 40, pingIDs: pingIDs
        )
        stay.source = source
        stay.category = .destination
        ctx.insert(stay)
        return stay
    }

    @discardableResult
    private func makeVisit(
        in ctx: ModelContext,
        stayID: UUID,
        arrival: Date,
        departure: Date? = nil,
        receivedAt: Date? = nil,
        latitude: Double? = nil
    ) -> Visit {
        let visit = Visit(
            arrivalDate: arrival,
            departureDate: departure,
            latitude: latitude ?? athens.lat,
            longitude: athens.lon,
            horizontalAccuracy: 20,
            receivedAt: receivedAt ?? departure ?? arrival,
            stayID: stayID,
            isProcessed: true
        )
        ctx.insert(visit)
        return visit
    }

    private func refetchStay(_ id: UUID, _ container: ModelContainer) throws -> Stay? {
        let predicate = #Predicate<Stay> { $0.id == id }
        return try ModelContext(container).fetch(FetchDescriptor<Stay>(predicate: predicate)).first
    }

    @Test("scan reports damage without mutating the store")
    func scanReportsWithoutMutating() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let liveA = makePing(in: ctx, source: .liveSLC, at: 10)
        let liveB = makePing(in: ctx, source: .liveSLC, at: 12)
        let dangling = UUID()
        let damaged = makeStay(
            in: ctx, source: .merged, startDay: 8, endDay: 12,
            pingIDs: [liveA.id, liveB.id, dangling]
        )
        let healthy = makeStay(
            in: ctx, source: .liveSLC, startDay: 20, endDay: 21,
            pingIDs: [makePing(in: ctx, source: .liveSLC, at: 20).id]
        )
        let hopeless = makeStay(
            in: ctx, source: .jsonImport, startDay: 30, endDay: 31,
            pingIDs: [UUID(), UUID()]
        )
        let damagedID = damaged.id
        let healthyID = healthy.id
        let hopelessID = hopeless.id
        try ctx.save()

        let report = await DebugStayReferenceRepair(modelContainer: container).scan()
        #expect(report.errorDescription == nil)
        #expect(report.scannedStays == 3)
        #expect(report.staysWithDanglingReferences == 2)
        #expect(report.danglingReferences == 3)
        #expect(report.repairedStays == 1)
        #expect(report.skippedNoSurvivingPings == 1)
        #expect(report.skippedInconsistent == 0)

        // Dry run: every row byte-identical.
        let scannedDamaged = try #require(try refetchStay(damagedID, container))
        #expect(scannedDamaged.pingIDs.count == 3)
        #expect(scannedDamaged.startTime == d(8))
        #expect(try refetchStay(healthyID, container)?.pingIDs.count == 1)
        #expect(try refetchStay(hopelessID, container)?.pingIDs.count == 2)
    }

    @Test("repair rebuilds from survivors, updates the trip, and is idempotent")
    func repairRebuildsFromSurvivorsAndUpdatesTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let liveA = makePing(in: ctx, source: .liveSLC, at: 10, latitude: 37.98)
        let liveB = makePing(in: ctx, source: .liveSLC, at: 12, latitude: 38.00)
        let dangling = UUID()
        // A `.merged` host whose photo ping was
        // deleted by an old discard; its window and centroid still carry
        // the deleted ping's contribution.
        let damaged = makeStay(
            in: ctx, source: .merged, startDay: 8, endDay: 12,
            pingIDs: [liveA.id, liveB.id, dangling]
        )
        let trip = Trip(startDate: d(8))
        trip.isComplete = true
        trip.endDate = d(12)
        ctx.insert(trip)
        damaged.trip = trip
        damaged.orderInTrip = 0
        let damagedID = damaged.id
        let tripID = trip.id
        try ctx.save()

        let repairer = DebugStayReferenceRepair(modelContainer: container)
        let report = await repairer.repair()
        #expect(report.errorDescription == nil)
        #expect(report.repairedStays == 1)
        #expect(report.updatedTrips == 1)

        let repaired = try #require(try refetchStay(damagedID, container))
        #expect(repaired.pingIDs == [liveA.id, liveB.id])
        #expect(repaired.pingCount == 2)
        #expect(repaired.startTime == d(10))
        #expect(repaired.endTime == d(12))
        #expect(repaired.durationMinutes == 2 * 24 * 60)
        #expect(abs(repaired.centroidLatitude - 37.99) < 1e-9)
        // All-live survivors: provenance reverts, same rule as the discard.
        #expect(repaired.source == .liveSLC)
        // Not geometric derivatives; preserved by the teardown rule.
        #expect(repaired.category == .destination)
        #expect(repaired.distanceFromHomeKm == 40)

        let tripPredicate = #Predicate<Trip> { $0.id == tripID }
        let reloadedTrip = try #require(
            try ModelContext(container).fetch(FetchDescriptor<Trip>(predicate: tripPredicate)).first
        )
        #expect(reloadedTrip.startDate == d(10))
        #expect(reloadedTrip.endDate == d(12))

        // Idempotence: a second pass finds nothing left to repair.
        let second = await repairer.repair()
        #expect(second.staysWithDanglingReferences == 0)
        #expect(second.repairedStays == 0)
    }

    @Test("Repair invalidates generated titles and recomputes the summary when stay bounds change")
    func repairInvalidatesTitlesWhenBoundsChange() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let livePing = makePing(in: ctx, source: .liveSLC, at: 20.5)
        let damaged = makeStay(
            in: ctx, source: .jsonImport, startDay: 20, endDay: 25,
            pingIDs: [livePing.id, UUID()]
        )
        let trip = Trip(startDate: d(20))
        trip.isComplete = true
        trip.endDate = d(25)
        trip.aiGeneratedTitle = "Stale Title"
        trip.titleSourceRevision = UUID()
        trip.destinationSummary = "Stale Summary"
        ctx.insert(trip)
        damaged.trip = trip
        damaged.orderInTrip = 0
        let damagedID = damaged.id
        let tripID = trip.id
        try ctx.save()

        let report = await DebugStayReferenceRepair(modelContainer: container).repair()
        #expect(report.errorDescription == nil)
        #expect(report.updatedTrips == 1)

        let repaired = try #require(try refetchStay(damagedID, container))
        let tripPredicate = #Predicate<Trip> { $0.id == tripID }
        let reloadedTrip = try #require(
            try ModelContext(container).fetch(FetchDescriptor<Trip>(predicate: tripPredicate)).first
        )
        #expect(reloadedTrip.endDate == repaired.endTime)
        #expect(reloadedTrip.aiGeneratedTitle == nil)
        #expect(reloadedTrip.titleSourceRevision == nil)
        #expect(reloadedTrip.destinationSummary != "Stale Summary")
    }

    @Test("a stay with no surviving pings is reported but never touched")
    func noSurvivorStayIsLeftUntouched() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let hopeless = makeStay(
            in: ctx, source: .jsonImport, startDay: 30, endDay: 31,
            pingIDs: [UUID(), UUID()]
        )
        let hopelessID = hopeless.id
        let originalIDs = hopeless.pingIDs
        try ctx.save()

        let repairer = DebugStayReferenceRepair(modelContainer: container)
        let report = await repairer.repair()
        #expect(report.errorDescription == nil)
        #expect(report.staysWithDanglingReferences == 1)
        #expect(report.skippedNoSurvivingPings == 1)
        #expect(report.repairedStays == 0)

        let untouched = try #require(try refetchStay(hopelessID, container))
        #expect(untouched.pingIDs == originalIDs)
        #expect(untouched.startTime == d(30))
    }

    @Test("a dangling-ping Stay rebuilds from Visit evidence alone")
    func danglingPingWithVisitRebuildsWithoutPings() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let damaged = makeStay(
            in: ctx, source: .merged, startDay: 29, endDay: 32,
            pingIDs: [UUID()]
        )
        let stayID = damaged.id
        let visit = makeVisit(
            in: ctx, stayID: stayID, arrival: d(30), departure: d(31),
            latitude: 38.25
        )
        let visitID = visit.id
        try ctx.save()

        let repairer = DebugStayReferenceRepair(modelContainer: container)
        let report = await repairer.repair()

        #expect(report.errorDescription == nil)
        #expect(report.scannedStays == 1)
        #expect(report.staysWithDanglingReferences == 1)
        #expect(report.repairedStays == 1)
        #expect(report.skippedNoSurvivingPings == 0)
        let repaired = try #require(try refetchStay(stayID, container))
        #expect(repaired.pingIDs.isEmpty)
        #expect(repaired.pingCount == 0)
        #expect(repaired.startTime == d(30))
        #expect(repaired.endTime == d(31))
        #expect(repaired.centroidLatitude == 38.25)
        #expect(repaired.source == .liveSLC)
        let savedVisit = try ModelContext(container).fetch(
            FetchDescriptor<Visit>(predicate: #Predicate { $0.id == visitID })
        ).first
        #expect(savedVisit?.stayID == stayID)
        let second = await repairer.repair()
        #expect(second.repairedStays == 0)
    }

    @Test("repair source matrix includes Visit-only, live, and imported pings")
    func visitRepairSourceMatrix() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let visitOnly = makeStay(
            in: ctx, source: .merged, startDay: 10, endDay: 11,
            pingIDs: [UUID()]
        )
        let livePing = makePing(in: ctx, source: .foregroundStream, at: 20.5)
        let live = makeStay(
            in: ctx, source: .merged, startDay: 20, endDay: 21,
            pingIDs: [livePing.id, UUID()]
        )
        let importedPing = makePing(in: ctx, source: .photoImport, at: 30.5)
        let imported = makeStay(
            in: ctx, source: .merged, startDay: 30, endDay: 31,
            pingIDs: [importedPing.id, UUID()]
        )
        makeVisit(in: ctx, stayID: visitOnly.id, arrival: d(10), departure: d(11))
        makeVisit(in: ctx, stayID: live.id, arrival: d(20), departure: d(21))
        makeVisit(in: ctx, stayID: imported.id, arrival: d(30), departure: d(31))
        let visitOnlyID = visitOnly.id
        let liveID = live.id
        let importedID = imported.id
        try ctx.save()

        let report = await DebugStayReferenceRepair(modelContainer: container).repair()

        #expect(report.errorDescription == nil)
        #expect(report.repairedStays == 3)
        #expect(try refetchStay(visitOnlyID, container)?.source == .liveSLC)
        #expect(try refetchStay(liveID, container)?.source == .liveSLC)
        #expect(try refetchStay(importedID, container)?.source == .merged)
    }

    @Test("neighbour clamps survive dangling-reference repair")
    func s3NeighbourClampSurvivesRepair() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let tuesday = d(1)
        let wednesday = d(2)
        let h1End = tuesday.addingTimeInterval(3_600)
        let h2Start = h1End.addingTimeInterval(1)
        let h3Start = wednesday.addingTimeInterval(8 * 3_600)
        let h2End = h3Start.addingTimeInterval(-1)

        let h1 = Stay(
            startTime: d(0).addingTimeInterval(18 * 3_600), endTime: h1End,
            centroidLatitude: athens.lat, centroidLongitude: athens.lon,
            h3IndexRes6: "8a2a1072b59ffff", pingCount: 0, distanceFromHomeKm: 0, pingIDs: []
        )
        let h2 = Stay(
            startTime: h2Start, endTime: h2End,
            centroidLatitude: athens.lat, centroidLongitude: athens.lon,
            h3IndexRes6: "8a2a1072b59ffff", pingCount: 1, distanceFromHomeKm: 0, pingIDs: [UUID()]
        )
        let h3 = Stay(
            startTime: h3Start, endTime: d(3),
            centroidLatitude: athens.lat, centroidLongitude: athens.lon,
            h3IndexRes6: "8a2a1072b59ffff", pingCount: 0, distanceFromHomeKm: 0, pingIDs: []
        )
        ctx.insert(h1)
        ctx.insert(h2)
        ctx.insert(h3)
        makeVisit(
            in: ctx,
            stayID: h2.id,
            arrival: tuesday.addingTimeInterval(30 * 60),
            departure: h3Start.addingTimeInterval(30 * 60)
        )
        let h2ID = h2.id
        try ctx.save()

        let report = await DebugStayReferenceRepair(modelContainer: container).repair()

        #expect(report.errorDescription == nil)
        #expect(report.repairedStays == 1)
        let repaired = try #require(try refetchStay(h2ID, container))
        #expect(repaired.startTime == h2Start)
        #expect(repaired.endTime == h2End)
        #expect(repaired.pingCount == 0)
    }

    // MARK: - UUID-twin parents

    /// Seeds one physical Trip row holding one stay. A damaged stay loses its
    /// earliest ping (`startDay`), so its repaired start is the next ping.
    private func makeTwinParent(
        in ctx: ModelContext, tripID: UUID, startDay: Double, endDay: Double,
        storedStart: Double, storedEnd: Double, damaged: Bool
    ) -> Trip {
        let trip = Trip(startDate: d(storedStart))
        trip.id = tripID
        trip.isComplete = true
        trip.endDate = d(storedEnd)
        ctx.insert(trip)
        let first = makePing(in: ctx, source: .liveSLC, at: startDay)
        let last = makePing(in: ctx, source: .liveSLC, at: endDay)
        let later = makePing(in: ctx, source: .liveSLC, at: startDay + 1)
        let pingIDs = damaged ? [UUID(), later.id, last.id] : [first.id, later.id, last.id]
        let stay = makeStay(in: ctx, source: .liveSLC, startDay: startDay, endDay: endDay, pingIDs: pingIDs)
        stay.trip = trip
        stay.orderInTrip = 0
        return trip
    }

    private func physicalTrip(_ identifier: PersistentIdentifier, _ container: ModelContainer) throws -> Trip? {
        try ModelContext(container).fetch(FetchDescriptor<Trip>()).first { $0.persistentModelID == identifier }
    }

    @Test("repair refreshes the bounds of every repaired UUID-twin parent, whatever the insertion order",
          arguments: [false, true])
    func repairRefreshesEveryTwinParent(secondInsertedFirst: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let sharedID = UUID()
        let specs: [(start: Double, end: Double)] = secondInsertedFirst
            ? [(40, 44), (8, 12)] : [(8, 12), (40, 44)]
        let trips = specs.map {
            makeTwinParent(in: ctx, tripID: sharedID, startDay: $0.start, endDay: $0.end,
                           storedStart: $0.start, storedEnd: $0.end, damaged: true)
        }
        try ctx.save()
        let identifiers = trips.map(\.persistentModelID)

        // The Diagnostics view runs the repair inside a gate unit.
        let repairer = DebugStayReferenceRepair(modelContainer: container)
        let report = await PipelineGate(forTesting: ()).runReturning(touching: [.stay, .trip]) {
            await repairer.repair()
        }

        #expect(report.errorDescription == nil)
        #expect(report.repairedStays == 2)
        #expect(report.updatedTrips == 2, "each physical parent is refreshed once")
        for (identifier, spec) in zip(identifiers, specs) {
            let trip = try #require(try physicalTrip(identifier, container))
            #expect(trip.startDate == d(spec.start + 1), "each twin takes its own repaired stay's start")
            #expect(trip.endDate == d(spec.end))
        }
        let second = await repairer.repair()
        #expect(second.repairedStays == 0)
        #expect(second.updatedTrips == 0)
    }

    @Test("repair leaves an undamaged UUID twin's stored bounds alone",
          arguments: [false, true])
    func repairLeavesUndamagedTwinAlone(damagedInsertedFirst: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let sharedID = UUID()
        func damagedTwin() -> Trip {
            makeTwinParent(in: ctx, tripID: sharedID, startDay: 40, endDay: 44,
                           storedStart: 40, storedEnd: 44, damaged: true)
        }
        // Stored bounds deliberately differ from its stay's, so a refresh would show.
        func healthyTwin() -> Trip {
            makeTwinParent(in: ctx, tripID: sharedID, startDay: 8, endDay: 12,
                           storedStart: 5, storedEnd: 13, damaged: false)
        }
        let damaged: Trip
        let healthy: Trip
        if damagedInsertedFirst {
            damaged = damagedTwin()
            healthy = healthyTwin()
        } else {
            healthy = healthyTwin()
            damaged = damagedTwin()
        }
        try ctx.save()
        let damagedIdentifier = damaged.persistentModelID
        let healthyIdentifier = healthy.persistentModelID

        let report = await DebugStayReferenceRepair(modelContainer: container).repair()

        #expect(report.errorDescription == nil)
        #expect(report.repairedStays == 1)
        #expect(report.updatedTrips == 1)
        let repairedTrip = try #require(try physicalTrip(damagedIdentifier, container))
        #expect(repairedTrip.startDate == d(41))
        #expect(repairedTrip.endDate == d(44))
        let untouched = try #require(try physicalTrip(healthyIdentifier, container))
        #expect(untouched.startDate == d(5))
        #expect(untouched.endDate == d(13))
    }
}
