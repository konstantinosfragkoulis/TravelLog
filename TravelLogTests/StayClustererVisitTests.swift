//
//  StayClustererVisitTests.swift
//  TravelLogTests
//

import CoreLocation
import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("StayClusterer Visit consumption")
struct StayClustererVisitTests {
    private static let base = Date(timeIntervalSince1970: 1_750_000_000)
    private static let lat = 0.0
    private static let lon = -140.0

    private func at(_ hour: Int, _ minute: Int = 0, _ second: Int = 0,
                    day: Int = 0) -> Date {
        Self.base.addingTimeInterval(TimeInterval(
            day * 86_400 + hour * 3_600 + minute * 60 + second))
    }

    private func longitude(metersEast: Double) -> Double {
        Self.lon + metersEast / 111_320
    }

    @discardableResult
    private func insertPing(_ context: ModelContext, at timestamp: Date,
                            metersEast: Double = 0,
                            processed: Bool = true) -> LocationPing {
        let lon = longitude(metersEast: metersEast)
        let ping = LocationPing(
            timestamp: timestamp, latitude: Self.lat, longitude: lon,
            horizontalAccuracy: 5,
            h3IndexRes6: H3Service.cellIndex(
                latitude: Self.lat, longitude: lon) ?? "")
        ping.isProcessed = processed
        context.insert(ping)
        return ping
    }

    @discardableResult
    private func insertStay(_ context: ModelContext, start: Date, end: Date,
                            metersEast: Double = 0,
                            source: DataSource = .liveSLC,
                            pingTimes: [Date] = []) -> Stay {
        let lon = longitude(metersEast: metersEast)
        let pings = pingTimes.map {
            insertPing(context, at: $0, metersEast: metersEast)
        }
        let stay = Stay(
            startTime: start, endTime: end,
            centroidLatitude: Self.lat, centroidLongitude: lon,
            h3IndexRes6: H3Service.cellIndex(
                latitude: Self.lat, longitude: lon) ?? "",
            pingCount: pings.count,
            distanceFromHomeKm: .greatestFiniteMagnitude,
            pingIDs: pings.map(\.id), source: source)
        context.insert(stay)
        return stay
    }

    @discardableResult
    private func insertVisit(
        _ context: ModelContext, id: UUID = UUID(), arrival: Date,
        departure: Date? = nil, receivedAt: Date? = nil,
        metersEast: Double = 0, stayID: UUID? = nil,
        processed: Bool = false
    ) -> Visit {
        let visit = Visit(
            id: id, arrivalDate: arrival, departureDate: departure,
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

    private func visits(_ container: ModelContainer) throws -> [Visit] {
        try ModelContext(container).fetch(FetchDescriptor<Visit>(
            sortBy: [SortDescriptor(\.arrivalDate, order: .forward)]))
    }

    private func windowCase(before: Bool, hours: Int) async throws -> Bool {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let arrival = at(12)
        let departure = at(13)
        let stay = before
            ? insertStay(
                context,
                start: arrival.addingTimeInterval(
                    TimeInterval(-(hours + 1) * 3_600)),
                end: arrival.addingTimeInterval(TimeInterval(-hours * 3_600)))
            : insertStay(context, start: departure.addingTimeInterval(
                TimeInterval(hours * 3_600)), end: at(18))
        let visit = insertVisit(
            context, arrival: arrival, departure: departure)
        try context.save()
        let clusterer = StayClusterer(modelContainer: container)
        _ = await clusterer.clusterUnprocessedPings()
        return try #require(visits(container).first { $0.id == visit.id }).stayID
            == stay.id
    }

    @Test("cancellation leaves unprocessed Visit groups available for the next pass")
    func cancelledVisitPassLeavesGroupsPending() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        insertVisit(context, arrival: at(1), departure: at(2))
        insertVisit(context, arrival: at(4), departure: at(5), metersEast: 5000)
        try context.save()
        let clusterer = StayClusterer(modelContainer: container)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await clusterer.clusterUnprocessedPings()
        }
        #expect(await cancelled.value == 0)
        #expect(try stays(container).isEmpty)
        #expect(try visits(container).allSatisfy { !$0.isProcessed })
    }

    @Test func visitOnlyClosed() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let visit = insertVisit(
            context, arrival: at(10), departure: at(12))
        try context.save()
        let clusterer = StayClusterer(modelContainer: container)

        #expect(await clusterer.clusterUnprocessedPings() == 1)
        let stay = try #require(try stays(container).first)
        let savedVisit = try #require(try visits(container).first)
        #expect(stay.startTime == at(10))
        #expect(stay.endTime == at(12))
        #expect(stay.pingCount == 0)
        #expect(stay.source == .liveSLC)
        #expect(savedVisit.id == visit.id && savedVisit.isProcessed)
        #expect(savedVisit.stayID == stay.id)
        #expect(try ModelContext(container).fetchCount(
            FetchDescriptor<HexVisit>()) == 0)
    }

    @Test func pingsFirst() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        insertPing(context, at: at(21, 58), metersEast: 400, processed: false)
        insertVisit(context, arrival: at(22), receivedAt: at(22, 7))
        try context.save()
        let clusterer = StayClusterer(modelContainer: container)

        #expect(await clusterer.clusterUnprocessedPings() == 1)
        let stay = try #require(try stays(container).first)
        #expect(try stays(container).count == 1)
        #expect(stay.startTime == at(21, 58))
        #expect(stay.endTime == at(22, 7))
        #expect(stay.pingCount == 1)
    }

    @Test func symmetricWindow() async throws {
        #expect(try await windowCase(before: true, hours: 2))
        #expect(try await windowCase(before: true, hours: 5) == false)
        #expect(try await windowCase(before: false, hours: 2))
        #expect(try await windowCase(before: false, hours: 5) == false)
    }

    @Test func nearestRanking() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let near = insertStay(
            context, start: at(10), end: at(14), metersEast: 100)
        insertStay(context, start: at(10), end: at(14), metersEast: 2_000)
        let visit = insertVisit(
            context, arrival: at(11), departure: at(13))
        try context.save()
        let clusterer = StayClusterer(modelContainer: container)
        _ = await clusterer.clusterUnprocessedPings()
        #expect(try visits(container).first { $0.id == visit.id }?.stayID == near.id)
    }

    @Test func overlapRanking() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        insertStay(context, start: at(10), end: at(11), metersEast: 100)
        let overlap = insertStay(
            context, start: at(10), end: at(14), metersEast: 250)
        let visit = insertVisit(
            context, arrival: at(11), departure: at(13))
        try context.save()
        let clusterer = StayClusterer(modelContainer: container)
        _ = await clusterer.clusterUnprocessedPings()
        #expect(try visits(container).first { $0.id == visit.id }?.stayID
                == overlap.id)
    }

    @Test func sourceTransitions() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let imported = insertStay(
            context, start: at(1), end: at(3), source: .photoImport)
        let live = insertStay(
            context, start: at(11), end: at(13), metersEast: 10_000)
        insertVisit(context, arrival: at(1), departure: at(2))
        insertVisit(
            context, arrival: at(11), departure: at(12), metersEast: 10_000)
        try context.save()
        let clusterer = StayClusterer(modelContainer: container)
        _ = await clusterer.clusterUnprocessedPings()
        let saved = try stays(container)
        #expect(saved.first { $0.id == imported.id }?.source == .merged)
        #expect(saved.first { $0.id == live.id }?.source == .liveSLC)
    }

    @Test func closedRetractsTailNotPing() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let stay = insertStay(
            context, start: at(10), end: at(12, 15), pingTimes: [at(10)])
        insertVisit(context, arrival: at(10, 5), departure: at(11, 55))
        try context.save()
        let clusterer = StayClusterer(modelContainer: container)
        _ = await clusterer.clusterUnprocessedPings()
        let saved = try #require(try stays(container).first { $0.id == stay.id })
        #expect(saved.startTime == at(10))
        #expect(saved.endTime == at(11, 55))
    }

    @Test func openEndKeepsExisting() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let stay = insertStay(context, start: at(22), end: at(22, 5))
        insertVisit(context, arrival: at(22), receivedAt: at(22, 3))
        try context.save()
        let clusterer = StayClusterer(modelContainer: container)
        _ = await clusterer.clusterUnprocessedPings()
        #expect(try stays(container).first { $0.id == stay.id }?.endTime == at(22, 5))
    }

    @Test func previousPullback() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let home = insertStay(
            context, start: at(17), end: at(20),
            pingTimes: [at(17), at(18)])
        let cafe = insertStay(
            context, start: at(22), end: at(22), metersEast: 4_000,
            pingTimes: [at(22)])
        insertVisit(
            context, arrival: at(19), departure: at(23), metersEast: 4_000)
        try context.save()
        let clusterer = StayClusterer(modelContainer: container)
        _ = await clusterer.clusterUnprocessedPings()
        let saved = try stays(container)
        #expect(saved.first { $0.id == home.id }?.endTime == at(18, 59))
        #expect(saved.first { $0.id == cafe.id }?.startTime == at(19))
        #expect(saved.first { $0.id == cafe.id }?.endTime == at(23))
    }

    @Test func closedPreviousClamps() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let previous = insertStay(
            context, start: at(17), end: at(20), pingTimes: [at(17)])
        insertVisit(
            context, arrival: at(17), departure: at(20), stayID: previous.id,
            processed: true)
        let target = insertStay(
            context, start: at(22), end: at(22), metersEast: 4_000)
        insertVisit(
            context, arrival: at(19), departure: at(23), metersEast: 4_000)
        try context.save()
        let clusterer = StayClusterer(modelContainer: container)
        _ = await clusterer.clusterUnprocessedPings()
        let saved = try stays(container)
        #expect(saved.first { $0.id == previous.id }?.endTime == at(20))
        #expect(saved.first { $0.id == target.id }?.startTime == at(20, 0, 1))
    }

    @Test func successorFloor() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        // Target overlaps the visit for 2 h, the successor for 1 h: both are
        // in the 300 m tie set, so the larger overlap selects the target.
        let target = insertStay(context, start: at(19), end: at(21))
        let next = insertStay(context, start: at(8, day: 1), end: at(9, day: 1))
        insertVisit(
            context, arrival: at(19), departure: at(10, day: 1))
        try context.save()
        let clusterer = StayClusterer(modelContainer: container)
        _ = await clusterer.clusterUnprocessedPings()
        let saved = try stays(container)
        #expect(saved.first { $0.id == target.id }?.endTime
                == next.startTime.addingTimeInterval(-1))
    }

    @Test func endNeverBeforeStart() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let previous = insertStay(context, start: at(17), end: at(23))
        insertVisit(
            context, arrival: at(17), departure: at(23), stayID: previous.id,
            processed: true)
        let target = insertStay(
            context, start: at(22), end: at(22), metersEast: 4_000)
        insertVisit(
            context, arrival: at(19), departure: at(20), metersEast: 4_000)
        try context.save()
        let clusterer = StayClusterer(modelContainer: container)
        _ = await clusterer.clusterUnprocessedPings()
        let saved = try #require(try stays(container).first { $0.id == target.id })
        #expect(saved.endTime >= saved.startTime)
    }

    @Test func closedBackingSkipsTail() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let closed = insertStay(
            context, start: at(10), end: at(10), pingTimes: [at(10)])
        insertVisit(
            context, arrival: at(10), departure: at(10, 30), stayID: closed.id,
            processed: true)
        insertPing(
            context, at: at(14), metersEast: 40_000, processed: false)
        try context.save()
        let clusterer = StayClusterer(modelContainer: container)
        _ = await clusterer.clusterUnprocessedPings()
        #expect(try stays(container).first { $0.id == closed.id }?.endTime == at(10))
    }

    /// A failed Visit backing read must abort before the ping walk: with an
    /// empty closed set the walk would extend the closed stay past its known
    /// departure, and no later pass retracts that tail.
    @Test func failedBackingReadDefersPingsAndVisits() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let closed = insertStay(
            context, start: at(10), end: at(10, 30), pingTimes: [at(10)])
        insertVisit(
            context, arrival: at(10), departure: at(10, 30), stayID: closed.id,
            processed: true)
        insertPing(
            context, at: at(14), metersEast: 40_000, processed: false)
        let pendingVisit = insertVisit(
            context, arrival: at(20), departure: at(21), metersEast: 80_000)
        try context.save()
        let clusterer = StayClusterer(modelContainer: container)

        let failed = await StayClusterer.ReadTestHook.$beforeVisitBackingRead
            .withValue({ throw CocoaError(.fileReadUnknown) }) {
                await clusterer.clusterUnprocessedPingsReportingChanges()
            }
        #expect(failed.failed)
        #expect(failed.created == 0)
        #expect(!failed.needsPublication)
        #expect(failed.pendingLocalities.candidates.isEmpty)
        #expect(failed.changes.isEmpty)
        let untouched = try stays(container)
        #expect(untouched.count == 1)
        #expect(untouched.first?.endTime == at(10, 30))
        #expect(untouched.first?.durationMinutes == 30)
        #expect(try ModelContext(container).fetch(FetchDescriptor<LocationPing>())
            .filter { !$0.isProcessed }.count == 1)
        #expect(try visits(container).first { $0.id == pendingVisit.id }?
            .isProcessed == false)

        // The same instance retries once the read succeeds: the closed stay
        // keeps its departure and the deferred work lands.
        let retried = await clusterer.clusterUnprocessedPingsReportingChanges()
        #expect(!retried.failed)
        #expect(retried.created == 2)
        let saved = try stays(container)
        #expect(saved.count == 3)
        #expect(saved.first { $0.id == closed.id }?.endTime == at(10, 30))
        #expect(saved.contains { $0.startTime == at(14) })
        #expect(try ModelContext(container).fetch(FetchDescriptor<LocationPing>())
            .allSatisfy(\.isProcessed))
        #expect(try visits(container).allSatisfy(\.isProcessed))

        // The next place's Visit starts at its arrival; an artificial tail on
        // the closed stay would have pushed it past the tail's end.
        let next = try #require(saved.first { $0.startTime == at(14) })
        insertVisit(
            context, arrival: at(11), departure: at(14, 30),
            metersEast: 40_000)
        try context.save()
        _ = await clusterer.clusterUnprocessedPings()
        let reconciled = try stays(container)
        #expect(reconciled.first { $0.id == next.id }?.startTime == at(11))
        #expect(reconciled.first { $0.id == closed.id }?.endTime == at(10, 30))
    }

    @Test func openBackingGetsTail() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let open = insertStay(
            context, start: at(10), end: at(10), pingTimes: [at(10)])
        insertVisit(
            context, arrival: at(10), receivedAt: at(10, 5),
            stayID: open.id, processed: true)
        insertPing(
            context, at: at(14), metersEast: 40_000, processed: false)
        try context.save()
        let clusterer = StayClusterer(modelContainer: container)
        _ = await clusterer.clusterUnprocessedPings()
        #expect(try stays(container).first { $0.id == open.id }?.endTime == at(12))
    }

    @Test func siblingIntervalsConverge() async throws {
        for reverse in [false, true] {
            let container = try TestSupport.makeInMemoryContainer()
            let context = ModelContext(container)
            let clusterer = StayClusterer(modelContainer: container)
            let first = { _ = self.insertVisit(
                context, arrival: self.at(18), departure: self.at(20)) }
            let second = { _ = self.insertVisit(
                context, arrival: self.at(20, 0, 1),
                departure: self.at(8, day: 1), metersEast: 464) }
            if reverse { second() } else { first() }
            try context.save()
            _ = await clusterer.clusterUnprocessedPings()
            if reverse { first() } else { second() }
            try context.save()
            _ = await clusterer.clusterUnprocessedPings()
            let saved = try stays(container)
            #expect(saved.count == 1)
            #expect(saved.first?.startTime == at(18))
            #expect(saved.first?.endTime == at(8, day: 1))
        }
    }

    @Test func missingLinkedStay() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        insertVisit(
            context, arrival: at(10), departure: at(11), stayID: UUID())
        try context.save()
        let clusterer = StayClusterer(modelContainer: container)
        #expect(await clusterer.clusterUnprocessedPings() == 0)
        #expect(try stays(container).isEmpty)
        #expect(try visits(container).allSatisfy(\.isProcessed))
    }

    @Test func displacedHosts() async throws {
        for pingBacked in [false, true] {
            let container = try TestSupport.makeInMemoryContainer()
            let context = ModelContext(container)
            let winner = insertStay(context, start: at(10), end: at(12))
            let displaced = insertStay(
                context, start: at(10), end: at(12), metersEast: 100,
                pingTimes: pingBacked ? [at(10)] : [])
            insertVisit(
                context, id: UUID(uuidString:
                    "00000000-0000-0000-0000-000000000001")!,
                arrival: at(10), departure: at(12), stayID: winner.id)
            insertVisit(
                context, id: UUID(uuidString:
                    "00000000-0000-0000-0000-000000000002")!,
                arrival: at(10), departure: at(12), metersEast: 100,
                stayID: displaced.id)
            try context.save()
            let clusterer = StayClusterer(modelContainer: container)
            _ = await clusterer.clusterUnprocessedPings()
            let saved = try stays(container)
            #expect(saved.contains { $0.id == winner.id })
            #expect(saved.contains { $0.id == displaced.id } == pingBacked)
            #expect(try visits(container).allSatisfy { $0.stayID == winner.id })
        }
    }

    /// A displaced zero-ping host the user corrected, or one in a trip the user
    /// edited, stays put: the duplicate is kept rather than the user's work lost.
    @Test(arguments: [false, true])
    func displacedUserOwnedHostsStay(inEditedTrip: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let winner = insertStay(context, start: at(10), end: at(12))
        let displaced = insertStay(
            context, start: at(10), end: at(12), metersEast: 100)
        if inEditedTrip {
            let trip = Trip(startDate: displaced.startTime)
            trip.userEdited = true
            context.insert(trip)
            displaced.trip = trip
            displaced.orderInTrip = 0
        } else {
            displaced.category = .destination
            displaced.userOverridden = true
        }
        insertVisit(
            context, id: UUID(uuidString:
                "00000000-0000-0000-0000-000000000001")!,
            arrival: at(10), departure: at(12), stayID: winner.id)
        insertVisit(
            context, id: UUID(uuidString:
                "00000000-0000-0000-0000-000000000002")!,
            arrival: at(10), departure: at(12), metersEast: 100,
            stayID: displaced.id)
        try context.save()
        let clusterer = StayClusterer(modelContainer: container)
        _ = await clusterer.clusterUnprocessedPings()
        let kept = try #require(try stays(container).first { $0.id == displaced.id })
        if inEditedTrip {
            #expect(kept.trip != nil)
        } else {
            #expect(kept.category == .destination && kept.userOverridden)
        }
        #expect(try visits(container).allSatisfy {
            $0.stayID == winner.id && $0.isProcessed
        })
    }

    @Test func zeroPingCentroidRefresh() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let visit = insertVisit(
            context, arrival: at(12), receivedAt: at(12, 5))
        try context.save()
        let clusterer = StayClusterer(modelContainer: container)
        _ = await clusterer.clusterUnprocessedPings()
        visit.departureDate = at(13)
        visit.receivedAt = at(13, 1)
        visit.longitude = longitude(metersEast: 500)
        visit.horizontalAccuracy = 1
        visit.isProcessed = false
        try context.save()
        _ = await clusterer.clusterUnprocessedPings()
        let stay = try #require(try stays(container).first)
        #expect(stay.centroidLongitude == longitude(metersEast: 500))
        #expect(stay.h3IndexRes6 == H3Service.cellIndex(
            latitude: Self.lat, longitude: longitude(metersEast: 500)))
    }

    @Test func tripAndDerivatives() async throws {
        for changesDaySpan in [false, true] {
            let container = try TestSupport.makeInMemoryContainer()
            let context = ModelContext(container)
            let target = insertStay(
                context, start: at(10), end: at(11), metersEast: 0)
            let successor = insertStay(
                context, start: at(20), end: at(21), metersEast: 10_000)
            let trip = Trip(startDate: target.startTime)
            trip.isComplete = true
            trip.endDate = successor.endTime
            context.insert(trip)
            target.trip = trip; target.orderInTrip = 0
            successor.trip = trip; successor.orderInTrip = 1
            target.transitFromPreviousRaw = "walking"
            target.distanceFromPreviousKm = 2
            successor.transitFromPreviousRaw = "walking"
            successor.distanceFromPreviousKm = 3
            target.weatherData = Data([1]); target.avgTemperatureC = 20
            target.weatherConditionRaw = "clear"; target.precipitationMm = 0
            target.dayKey = at(0)
            insertVisit(
                context,
                arrival: changesDaySpan ? at(0, day: -1) : at(9),
                departure: at(12))
            try context.save()
            let clusterer = StayClusterer(modelContainer: container)
            _ = await clusterer.clusterUnprocessedPings()
            let saved = try #require(try stays(container).first {
                $0.id == target.id
            })
            #expect(saved.transitFromPreviousRaw == nil)
            #expect(saved.distanceFromPreviousKm == nil)
            #expect(try stays(container).first {
                $0.id == successor.id
            }?.transitFromPreviousRaw == nil)
            #expect((saved.weatherData == nil) == changesDaySpan)
            let savedTrip = try #require(try ModelContext(container).fetch(
                FetchDescriptor<Trip>()).first)
            #expect(savedTrip.startDate == saved.startTime)
            #expect(savedTrip.endDate == successor.endTime)
        }
    }

    @Test("each leg follows its own boundary: an end-only move keeps the stay's inbound flight and clears the next leg; a start-only move does the reverse")
    func intervalDerivativesFollowTheirBoundary() async throws {
        for startMoves in [false, true] {
            let container = try TestSupport.makeInMemoryContainer()
            let context = ModelContext(container)
            let target = insertStay(
                context, start: at(10), end: at(11), metersEast: 0)
            let successor = insertStay(
                context, start: at(20), end: at(21), metersEast: 10_000)
            // A flight confirmed while still at the arrival airport.
            target.transitFromPreviousRaw = TransitMode.flight.rawValue
            target.distanceFromPreviousKm = 2
            successor.transitFromPreviousRaw = "walking"
            successor.distanceFromPreviousKm = 3
            insertVisit(
                context,
                arrival: startMoves ? at(9) : at(10, 30),
                departure: startMoves ? at(11) : at(12))
            try context.save()
            let clusterer = StayClusterer(modelContainer: container)
            _ = await clusterer.clusterUnprocessedPings()
            let rows = try stays(container)
            let saved = try #require(rows.first { $0.id == target.id })
            let next = try #require(rows.first { $0.id == successor.id })
            #expect(saved.startTime == (startMoves ? at(9) : at(10)))
            #expect(saved.endTime == (startMoves ? at(11) : at(12)))
            if startMoves {
                #expect(saved.transitFromPreviousRaw == nil)
                #expect(saved.distanceFromPreviousKm == nil)
                #expect(next.transitFromPreviousRaw == "walking")
                #expect(next.distanceFromPreviousKm == 3)
            } else {
                #expect(saved.transitFromPreviousRaw == TransitMode.flight.rawValue)
                #expect(saved.distanceFromPreviousKm == 2)
                #expect(next.transitFromPreviousRaw == nil)
                #expect(next.distanceFromPreviousKm == nil)
            }
        }
    }

    @Test func pingCommitPrecedesMissingLink() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        insertPing(context, at: at(8), processed: false)
        insertVisit(
            context, arrival: at(18), departure: at(19), stayID: UUID())
        try context.save()
        let clusterer = StayClusterer(modelContainer: container)
        #expect(await clusterer.clusterUnprocessedPings() == 1)
        #expect(try stays(container).count == 1)
    }
}
