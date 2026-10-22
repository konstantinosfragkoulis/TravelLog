//
//  StayClustererContainingVisitTests.swift
//  TravelLogTests
//
//  A closed Visit far from home, delivered after the same-place fixes either
//  side of it folded into one stay: the outing keeps its interval and the
//  fixes after its departure become their own stay. Controls keep every
//  host the split must not touch as it was.
//

import CoreLocation
import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("StayClusterer Visit inside a ping stay", IsolatedLineageDefaults())
struct StayClustererContainingVisitTests {
    private static let base = Date(timeIntervalSinceReferenceDate: 820_000_000)
    private static let lat = 44.3
    private static let lon = 12.9
    private static let awayMeters = 40_000.0

    private func at(_ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        Self.base.addingTimeInterval(TimeInterval(hour * 3_600 + minute * 60 + second))
    }

    private func longitude(metersEast: Double) -> Double {
        Self.lon + metersEast / (111_320 * cos(Self.lat * .pi / 180))
    }

    @discardableResult
    private func insertPing(
        _ context: ModelContext, at timestamp: Date, metersEast: Double = 0,
        source: DataSource = .liveSLC
    ) -> LocationPing {
        let lon = longitude(metersEast: metersEast)
        let ping = LocationPing(
            timestamp: timestamp, latitude: Self.lat, longitude: lon,
            horizontalAccuracy: 5,
            h3IndexRes6: H3Service.cellIndex(latitude: Self.lat, longitude: lon) ?? "",
            source: source)
        ping.isProcessed = false
        context.insert(ping)
        return ping
    }

    @discardableResult
    private func insertVisit(
        _ context: ModelContext, arrival: Date, departure: Date?,
        receivedAt: Date? = nil, metersEast: Double = Self.awayMeters,
        stayID: UUID? = nil, processed: Bool = false
    ) -> Visit {
        let visit = Visit(
            arrivalDate: arrival, departureDate: departure,
            latitude: Self.lat, longitude: longitude(metersEast: metersEast),
            horizontalAccuracy: 5,
            receivedAt: receivedAt ?? departure ?? arrival,
            stayID: stayID, isProcessed: processed)
        context.insert(visit)
        return visit
    }

    private func stays(_ container: ModelContainer) throws -> [Stay] {
        try ModelContext(container).fetch(FetchDescriptor<Stay>(
            sortBy: [SortDescriptor(\.startTime, order: .forward)]))
    }

    private func linkedStayID(of visitID: UUID, _ container: ModelContainer) throws -> UUID? {
        try ModelContext(container).fetch(FetchDescriptor<Visit>())
            .first { $0.id == visitID }?.stayID
    }

    /// Strictly ordered, never overlapping, every fix on exactly one stay.
    private func expectPartition(
        _ saved: [Stay], pings: [LocationPing], _ container: ModelContainer
    ) throws {
        for (earlier, later) in zip(saved, saved.dropFirst()) {
            #expect(earlier.endTime < later.startTime)
            #expect(earlier.startTime <= earlier.endTime)
        }
        let held = saved.flatMap(\.pingIDs)
        #expect(held.count == Set(held).count)
        #expect(Set(held) == Set(pings.map(\.id)))
        #expect(saved.allSatisfy { $0.pingCount == $0.pingIDs.count })
    }

    /// Fixes at home, then the away Visit: in the same pass, or after the
    /// fixes were clustered (the host then takes `prepareHost`).
    private func runScenario(
        fixes: [Date], visit: (arrival: Date, departure: Date),
        late: Bool, prepareHost: ((Stay, ModelContext) throws -> Void)? = nil
    ) async throws -> (container: ModelContainer, pings: [LocationPing], visitID: UUID,
                       hostRow: PersistentIdentifier?) {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let pings = fixes.map { insertPing(context, at: $0) }
        try context.save()
        let clusterer = StayClusterer(modelContainer: container)
        var hostRow: PersistentIdentifier?
        if late {
            _ = await clusterer.clusterUnprocessedPings()
            let edit = ModelContext(container)
            let host = try #require(try edit.fetch(FetchDescriptor<Stay>()).first)
            #expect(host.pingIDs == pings.map(\.id))
            try prepareHost?(host, edit)
            try edit.save()
            hostRow = host.persistentModelID
        }
        let visitID = insertVisit(
            context, arrival: visit.arrival, departure: visit.departure).id
        try context.save()
        _ = await clusterer.clusterUnprocessedPings()
        return (container, pings, visitID, hostRow)
    }

    @Test("an away Visit between two same-place fixes exactly four hours apart keeps its interval, in the same pass or delivered late",
          arguments: [false, true])
    func awayVisitInsideSamePlaceFixes(late: Bool) async throws {
        let run = try await runScenario(
            fixes: [at(8), at(12)], visit: (at(8, 30), at(11, 30)), late: late) { host, _ in
                host.category = .home
            }
        let saved = try stays(run.container)
        #expect(saved.count == 3)
        try expectPartition(saved, pings: run.pings, run.container)

        let host = saved[0]
        #expect(host.startTime == at(8))
        #expect(host.endTime == at(8, 29))
        #expect(host.pingIDs == [run.pings[0].id])
        if let hostRow = run.hostRow {
            #expect(host.persistentModelID == hostRow, "the original row keeps the earlier fixes")
        }
        // Both pieces are judged again on their own dates and place.
        #expect(host.category == .unclassified)

        let outing = saved[1]
        #expect(try linkedStayID(of: run.visitID, run.container) == outing.id)
        #expect(outing.startTime == at(8, 30))
        #expect(outing.endTime == at(11, 30))
        #expect(outing.durationMinutes == 180)
        #expect(outing.pingCount == 0)

        let resumed = saved[2]
        #expect(resumed.startTime == at(12))
        #expect(resumed.endTime == at(12))
        #expect(resumed.pingIDs == [run.pings[1].id])
        #expect(resumed.category == .unclassified)
    }

    @Test("the resumed piece never inherits the host's verdict; a temporary home's stamp stays on the host alone",
          arguments: [false, true])
    func splitPiecesAreJudgedAgain(temporaryStamp: Bool) async throws {
        let temporaryHomeID = UUID()
        let run = try await runScenario(
            fixes: [at(8), at(12)], visit: (at(8, 30), at(11, 30)), late: true) { host, _ in
                host.category = .home
                if temporaryStamp { host.setTemporaryHomeProvenance(temporaryHomeID, revision: 3) }
            }
        let saved = try stays(run.container)
        #expect(saved.count == 3)
        let host = saved[0]
        let resumed = saved[2]
        #expect(host.persistentModelID == run.hostRow)
        #expect(host.category == (temporaryStamp ? .home : .unclassified))
        #expect(host.temporaryHomeID == (temporaryStamp ? temporaryHomeID : nil))
        #expect(host.temporaryHomeRevision == (temporaryStamp ? 3 : nil))
        #expect(resumed.startTime == at(12))
        #expect(resumed.category == .unclassified)
        #expect(resumed.temporaryHomeID == nil && resumed.temporaryHomeRevision == nil)
    }

    /// `legacyMembership`: the host lists the twinned fix twice, as clustering
    /// recorded kept twins before it took each UUID once.
    @Test("equal ping twins around an away Visit are one fix: the outing keeps its interval and both rows stay",
          arguments: [false, true])
    func pingTwinsAroundAwayVisit(legacyMembership: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let pings = [at(8), at(12)].map { insertPing(context, at: $0, source: .photoImport) }
        let copy = insertPing(context, at: at(8), source: .photoImport)
        copy.id = pings[0].id
        try context.save()
        let clusterer = StayClusterer(modelContainer: container)
        _ = await clusterer.clusterUnprocessedPings()
        let edit = ModelContext(container)
        let row = try #require(try edit.fetch(FetchDescriptor<Stay>()).first)
        #expect(row.pingIDs == pings.map(\.id))
        if legacyMembership {
            row.pingIDs = [pings[0].id, pings[0].id, pings[1].id]
            row.pingCount = 3
        }
        try edit.save()
        let hostRow = row.persistentModelID

        let visit = insertVisit(context, arrival: at(8, 30), departure: at(11, 30))
        try context.save()
        _ = await clusterer.clusterUnprocessedPings()

        let saved = try stays(container)
        #expect(saved.count == 3)
        try expectPartition(saved, pings: pings, container)
        #expect(saved[0].persistentModelID == hostRow)
        #expect(saved[0].pingIDs == [pings[0].id])
        #expect(saved[0].endTime == at(8, 29))
        #expect(try linkedStayID(of: visit.id, container) == saved[1].id)
        #expect(saved[1].startTime == at(8, 30) && saved[1].endTime == at(11, 30))
        #expect(saved[2].pingIDs == [pings[1].id])
        let rows = try ModelContext(container).fetch(FetchDescriptor<LocationPing>())
        #expect(rows.filter { $0.id == pings[0].id }.count == 2)
    }

    @Test("fixes on both sides of the outing keep their home dwell before and after it")
    func bracketKeepsHomeDwell() async throws {
        let run = try await runScenario(
            fixes: [at(7, 30), at(8), at(12), at(12, 30)],
            visit: (at(8, 30), at(11, 30)), late: true)
        let saved = try stays(run.container)
        #expect(saved.count == 3)
        try expectPartition(saved, pings: run.pings, run.container)
        #expect(saved[0].persistentModelID == run.hostRow)
        #expect(saved[0].startTime == at(7, 30) && saved[0].endTime == at(8, 29))
        #expect(saved[0].pingIDs == run.pings.prefix(2).map(\.id))
        #expect(saved[1].startTime == at(8, 30) && saved[1].endTime == at(11, 30))
        #expect(saved[2].startTime == at(12) && saved[2].endTime == at(12, 30))
        #expect(saved[2].pingIDs == run.pings.suffix(2).map(\.id))
    }

    @Test("two away Visits inside the fixes each keep their interval, delivered together or the later one first",
          arguments: [false, true])
    func twoVisitsInEitherOrder(laterFirst: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let pings = [at(8), at(12)].map { insertPing(context, at: $0) }
        let second = insertVisit(context, arrival: at(10), departure: at(11, 30), metersEast: 60_000)
        try context.save()
        let clusterer = StayClusterer(modelContainer: container)
        if laterFirst { _ = await clusterer.clusterUnprocessedPings() }
        let first = insertVisit(context, arrival: at(8, 30), departure: at(9, 30))
        try context.save()
        _ = await clusterer.clusterUnprocessedPings()

        let saved = try stays(container)
        #expect(saved.count == 4)
        try expectPartition(saved, pings: pings, container)
        #expect(saved[0].startTime == at(8) && saved[0].endTime == at(8, 29))
        #expect(try linkedStayID(of: first.id, container) == saved[1].id)
        #expect(saved[1].startTime == at(8, 30) && saved[1].endTime == at(9, 30))
        #expect(try linkedStayID(of: second.id, container) == saved[2].id)
        #expect(saved[2].startTime == at(10) && saved[2].endTime == at(11, 30))
        #expect(saved[3].startTime == at(12) && saved[3].endTime == at(12))
    }

    @Test("a replayed copy of the Visit selects the same rows and moves nothing")
    func replayIsIdempotent() async throws {
        let run = try await runScenario(
            fixes: [at(8), at(12)], visit: (at(8, 30), at(11, 30)), late: true)
        let before = try stays(run.container).map { [$0.id.uuidString, "\($0.startTime)", "\($0.endTime)", $0.pingIDsString] }
        let outingID = try #require(try linkedStayID(of: run.visitID, run.container))

        let context = ModelContext(run.container)
        let copy = insertVisit(context, arrival: at(8, 30), departure: at(11, 30))
        try context.save()
        _ = await StayClusterer(modelContainer: run.container).clusterUnprocessedPings()

        let after = try stays(run.container).map { [$0.id.uuidString, "\($0.startTime)", "\($0.endTime)", $0.pingIDsString] }
        #expect(after == before)
        #expect(try linkedStayID(of: copy.id, run.container) == outingID)
    }

    @Test("an open copy placed past the return moves back once its departure lands")
    func openThenClosedCopy() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let pings = [at(8), at(12)].map { insertPing(context, at: $0) }
        insertVisit(context, arrival: at(8, 30), departure: nil, receivedAt: at(12, 5))
        try context.save()
        let clusterer = StayClusterer(modelContainer: container)
        _ = await clusterer.clusterUnprocessedPings()
        // Without a departure nothing is split: the outing is not certified.
        #expect(try stays(container).first?.pingIDs == pings.map(\.id))

        insertVisit(context, arrival: at(8, 30), departure: at(11, 30), receivedAt: at(12, 10))
        try context.save()
        _ = await clusterer.clusterUnprocessedPings()
        let saved = try stays(container)
        #expect(saved.count == 3)
        try expectPartition(saved, pings: pings, container)
        #expect(saved[0].endTime == at(8, 29))
        #expect(saved[1].startTime == at(8, 30) && saved[1].endTime == at(11, 30))
        #expect(saved[2].startTime == at(12))
    }

    @Test("fixes a second over four hours apart, or at another place, are two stays already and the Visit fits between them")
    func controlsAlreadySeparateStays() async throws {
        for (secondFix, metersEast) in [(at(12, 0, 1), 0.0), (at(12), 5_000)] {
            let container = try TestSupport.makeInMemoryContainer()
            let context = ModelContext(container)
            let pings = [insertPing(context, at: at(8)),
                         insertPing(context, at: secondFix, metersEast: metersEast)]
            let visit = insertVisit(context, arrival: at(8, 30), departure: at(11, 30))
            try context.save()
            _ = await StayClusterer(modelContainer: container).clusterUnprocessedPings()
            let saved = try stays(container)
            #expect(saved.count == 3)
            try expectPartition(saved, pings: pings, container)
            #expect(saved.map(\.pingIDs) == [[pings[0].id], [], [pings[1].id]])
            #expect(try linkedStayID(of: visit.id, container) == saved[1].id)
            #expect(saved[1].startTime == at(8, 30) && saved[1].endTime == at(11, 30))
        }
    }

    /// A host the split leaves as it was.
    enum DeclinedHost: CaseIterable, Sendable {
        case fixDuringVisit
        case userSet
        case tripMember
        case visitBacked
        case restoredEndpoints
        case openVisit
    }

    @Test("the split never takes apart a host with a fix during the Visit, one the user set, a trip member, a Visit-backed or restored host, or for an open Visit",
          arguments: DeclinedHost.allCases)
    func declinedHostsKeepTheirFixes(_ host: DeclinedHost) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let fixes = host == .fixDuringVisit ? [at(8), at(10), at(12)] : [at(8), at(12)]
        let source: DataSource = host == .restoredEndpoints ? .jsonImport : .liveSLC
        let pings = fixes.map { insertPing(context, at: $0, source: source) }
        try context.save()
        let clusterer = StayClusterer(modelContainer: container)
        _ = await clusterer.clusterUnprocessedPings()

        let edit = ModelContext(container)
        let row = try #require(try edit.fetch(FetchDescriptor<Stay>()).first)
        switch host {
        case .userSet:
            row.category = .home
            row.userOverridden = true
        case .tripMember:
            let trip = Trip(startDate: row.startTime)
            edit.insert(trip)
            row.trip = trip
            row.orderInTrip = 0
        case .visitBacked:
            insertVisit(edit, arrival: at(7, 55), departure: nil, metersEast: 0,
                        stayID: row.id, processed: true)
        case .fixDuringVisit, .restoredEndpoints, .openVisit:
            break
        }
        try edit.save()
        let hostRow = row.persistentModelID

        insertVisit(context, arrival: at(8, 30),
                    departure: host == .openVisit ? nil : at(11, 30),
                    receivedAt: at(12, 5))
        try context.save()
        _ = await clusterer.clusterUnprocessedPings()

        let saved = try stays(container)
        #expect(saved.count == 2, "no stay is split off the host")
        let kept = try #require(saved.first { $0.persistentModelID == hostRow })
        #expect(kept.pingIDs == pings.map(\.id))
        #expect(kept.startTime == at(8))
        // A restore's endpoint fixes measure nothing, so that host is pulled
        // back as before; every other one keeps its return.
        if host != .restoredEndpoints { #expect(kept.endTime >= at(12)) }
    }

    @Test("the outing carved from a home stay is a destination on a trip, not a zero-minute transit")
    func carvedOutingIsTripEligible() async throws {
        try await StayClassificationInference.TestHook.$availability.withValue(false) {
            let container = try TestSupport.makeInMemoryContainer()
            let context = ModelContext(container)
            context.insert(Home(
                label: "Home", latitude: Self.lat, longitude: Self.lon,
                radiusKm: 1, startedAt: at(0).addingTimeInterval(-86_400)))
            for fix in [at(7, 30), at(8), at(12), at(12, 30)] { insertPing(context, at: fix) }
            let visit = insertVisit(context, arrival: at(8, 30), departure: at(11, 30))
            try context.save()
            _ = await StayClusterer(modelContainer: container).clusterUnprocessedPings()
            let classifier = TripClassifier(modelContainer: container)
            _ = await classifier.classifyAndAssembleTripsWithGates()

            let outingID = try #require(try linkedStayID(of: visit.id, container))
            #expect(await classifier.stayCategoryForTesting(outingID) == .destination)
            let trips = try ModelContext(container).fetch(FetchDescriptor<Trip>())
            #expect(trips.contains { ($0.stays ?? []).contains { $0.id == outingID } })
        }
    }
}
