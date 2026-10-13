//
//  CLVisitScenarioReplayTests.swift
//  TravelLogTests
//

import CoreLocation
import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("CLVisit scenario replay", .serialized)
struct CLVisitScenarioReplayTests {
    private static let base = Date(timeIntervalSince1970: 1_750_000_000)
    private static let lat = 0.0
    private static let lon = -140.0

    private struct StubVisit: VisitEventSource {
        let coordinate: CLLocationCoordinate2D
        let horizontalAccuracy: CLLocationAccuracy
        let arrivalDate: Date
        let departureDate: Date
    }

    private func at(_ hour: Int, _ minute: Int = 0, _ second: Int = 0,
                    day: Int = 0) -> Date {
        Self.base.addingTimeInterval(TimeInterval(
            day * 86_400 + hour * 3_600 + minute * 60 + second))
    }

    private func longitude(_ metersEast: Double) -> Double {
        Self.lon + metersEast / 111_320
    }

    private func location(at timestamp: Date, metersEast: Double = 0) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude: Self.lat, longitude: longitude(metersEast)),
            altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
            course: -1, speed: -1, timestamp: timestamp)
    }

    private func recordPings(
        _ recorder: PingRecorder,
        _ values: [(Date, Double)]
    ) async {
        await recorder.processLocations(values.map {
            LiveLocationCandidate(
                location(at: $0.0, metersEast: $0.1), source: .liveSLC)
        }, defaults: TestSupport.liveFloorFreeDefaults)
    }

    /// Takes the suite name, so the recorder actor gets its own defaults handle.
    private func recordVisit(
        _ recorder: VisitRecorder,
        suiteName: String,
        arrival: Date,
        departure: Date? = nil,
        receivedAt: Date,
        metersEast: Double = 0,
        accuracy: Double = 5
    ) async {
        await recorder.record(VisitObservation(
            source: StubVisit(
                coordinate: CLLocationCoordinate2D(
                    latitude: Self.lat, longitude: longitude(metersEast)),
                horizontalAccuracy: accuracy,
                arrivalDate: arrival,
                departureDate: departure ?? .distantFuture),
            receivedAt: receivedAt), defaults: UserDefaults(suiteName: suiteName)!)
    }

    private func stays(_ container: ModelContainer) throws -> [Stay] {
        try ModelContext(container).fetch(FetchDescriptor<Stay>(
            sortBy: [SortDescriptor(\.startTime, order: .forward)]))
    }

    private func visits(_ container: ModelContainer) throws -> [Visit] {
        try ModelContext(container).fetch(FetchDescriptor<Visit>())
    }

    private func pings(_ container: ModelContainer) throws -> [LocationPing] {
        try ModelContext(container).fetch(FetchDescriptor<LocationPing>(
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]))
    }

    private func expectInterval(_ stay: Stay?, _ start: Date, _ end: Date) throws {
        let stay = try #require(stay)
        #expect(abs(stay.startTime.timeIntervalSince(start)) <= 1)
        #expect(abs(stay.endTime.timeIntervalSince(end)) <= 1)
    }

    @Test("an open visit's stay ends at its receipt until the departure lands; a later ping starts a new stay")
    func t1() async throws {
        let suiteName = "CLVisitScenarioReplayTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try TestSupport.makeInMemoryContainer()
        let pingRecorder = PingRecorder(modelContainer: container)
        let visitRecorder = VisitRecorder(modelContainer: container)
        let clusterer = StayClusterer(modelContainer: container)
        await recordPings(pingRecorder, [(at(21, 58), 400)])
        await recordVisit(
            visitRecorder, suiteName: suiteName, arrival: at(22), receivedAt: at(22, 7))
        #expect(await clusterer.clusterUnprocessedPings() == 1)
        try expectInterval(try stays(container).first, at(21, 58), at(22, 7))

        await recordVisit(
            visitRecorder, suiteName: suiteName, arrival: at(22), departure: at(9, day: 1),
            receivedAt: at(9, 5, day: 1))
        await recordPings(pingRecorder, [(at(9, 10, day: 1), 40_000)])
        #expect(await clusterer.clusterUnprocessedPings() == 1)
        let saved = try stays(container)
        #expect(saved.count == 2)
        try expectInterval(saved.first, at(21, 58), at(9, day: 1))
        try expectInterval(saved.last, at(9, 10, day: 1), at(9, 10, day: 1))
    }

    @Test("a visit 4 km from the pings carves its own stay between them in the same pass")
    func t2VariantA() async throws {
        let suiteName = "CLVisitScenarioReplayTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try TestSupport.makeInMemoryContainer()
        let pingRecorder = PingRecorder(modelContainer: container)
        let visitRecorder = VisitRecorder(modelContainer: container)
        let clusterer = StayClusterer(modelContainer: container)
        await recordPings(pingRecorder, [(at(8, 30), 0), (at(14), 9_000)])
        await recordVisit(
            visitRecorder, suiteName: suiteName, arrival: at(9, 15), departure: at(11, 30),
            receivedAt: at(14, 4), metersEast: 4_000)
        _ = await clusterer.clusterUnprocessedPings()
        let saved = try stays(container)
        #expect(saved.count == 3)
        try expectInterval(saved[0], at(8, 30), at(9, 14))
        try expectInterval(saved[1], at(9, 15), at(11, 30))
        try expectInterval(saved[2], at(14), at(14))
    }

    @Test("a visit 4 km from the pings carves its own stay after they were clustered")
    func t2VariantB() async throws {
        let suiteName = "CLVisitScenarioReplayTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try TestSupport.makeInMemoryContainer()
        let pingRecorder = PingRecorder(modelContainer: container)
        let visitRecorder = VisitRecorder(modelContainer: container)
        let clusterer = StayClusterer(modelContainer: container)
        await recordPings(pingRecorder, [(at(8, 30), 0), (at(14), 9_000)])
        _ = await clusterer.clusterUnprocessedPings()
        await recordVisit(
            visitRecorder, suiteName: suiteName, arrival: at(9, 15), departure: at(11, 30),
            receivedAt: at(17), metersEast: 4_000)
        _ = await clusterer.clusterUnprocessedPings()
        let saved = try stays(container)
        #expect(saved.count == 3)
        try expectInterval(saved[0], at(8, 30), at(9, 14))
        try expectInterval(saved[1], at(9, 15), at(11, 30))
        try expectInterval(saved[2], at(14), at(14))
    }

    @Test("an open visit 40 km from home is transit, then a destination capped 12 hours after receipt")
    func t3Classification() async throws {
        // Disable model inference to keep the heuristic verdict deterministic.
        try await StayClassificationInference.TestHook.$availability.withValue(false) {
            let suiteName = "CLVisitScenarioReplayTests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let container = try TestSupport.makeInMemoryContainer()
            let pingRecorder = PingRecorder(modelContainer: container)
            let visitRecorder = VisitRecorder(modelContainer: container)
            let clusterer = StayClusterer(modelContainer: container)
            let classifier = TripClassifier(modelContainer: container)
            let ctx = ModelContext(container)
            ctx.insert(Home(
                label: "Home", latitude: Self.lat, longitude: Self.lon,
                radiusKm: 1, startedAt: at(0, day: -1)))
            try ctx.save()

            await recordPings(pingRecorder, [(at(22, 1), 40_000)])
            await recordVisit(
                visitRecorder, suiteName: suiteName, arrival: at(22), receivedAt: at(22, 7),
                metersEast: 40_000)
            _ = await clusterer.clusterUnprocessedPings()
            _ = await classifier.classifyAndAssembleTripsWithGates()

            let hotelID = try #require(try visits(container).first?.stayID)
            #expect(await classifier.stayCategoryForTesting(hotelID) == .transit)

            await recordPings(pingRecorder, [(at(9, 10, day: 3), 80_000)])
            _ = await clusterer.clusterUnprocessedPings()
            _ = await classifier.classifyAndAssembleTripsWithGates()

            let saved = try stays(container)
            let hotel = try #require(saved.first { $0.id == hotelID })
            try expectInterval(hotel, at(22), at(10, 7, day: 1))
            #expect(hotel.durationMinutes == 727)
            #expect(await classifier.stayCategoryForTesting(hotelID) == .destination)
        }
    }

    @Test("a closed visit merges the earlier-clustered ping and the departure ping into one stay")
    func s1EarlierVisitPass() async throws {
        let suiteName = "CLVisitScenarioReplayTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try TestSupport.makeInMemoryContainer()
        let pingRecorder = PingRecorder(modelContainer: container)
        let visitRecorder = VisitRecorder(modelContainer: container)
        let clusterer = StayClusterer(modelContainer: container)
        await recordPings(pingRecorder, [(at(19), 0)])
        _ = await clusterer.clusterUnprocessedPings()
        await recordVisit(
            visitRecorder, suiteName: suiteName, arrival: at(19), departure: at(8, day: 1),
            receivedAt: at(8, 5, day: 1))
        _ = await clusterer.clusterUnprocessedPings()
        await recordPings(pingRecorder, [(at(8, day: 1), 0)])
        _ = await clusterer.clusterUnprocessedPings()
        let stay = try #require(try stays(container).first)
        #expect(try stays(container).count == 1 && stay.pingCount == 2)
        try expectInterval(stay, at(19), at(8, day: 1))
    }

    @Test("a closed visit clustered with its pings in one pass ends just before the departure ping's stay")
    func s1SamePass() async throws {
        let suiteName = "CLVisitScenarioReplayTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try TestSupport.makeInMemoryContainer()
        let pingRecorder = PingRecorder(modelContainer: container)
        let visitRecorder = VisitRecorder(modelContainer: container)
        let clusterer = StayClusterer(modelContainer: container)
        await recordPings(pingRecorder, [(at(19), 0), (at(8, day: 1), 0)])
        await recordVisit(
            visitRecorder, suiteName: suiteName, arrival: at(19), departure: at(8, day: 1),
            receivedAt: at(8, 5, day: 1))
        _ = await clusterer.clusterUnprocessedPings()
        let saved = try stays(container)
        #expect(saved.count == 2)
        try expectInterval(saved[0], at(19), at(7, 59, 59, day: 1))
        try expectInterval(saved[1], at(8, day: 1), at(8, day: 1))
    }

    @Test("a home visit that closes later completes an existing open trip")
    func s2ClosesOpenTripAfterClosedVisit() async throws {
        let suiteName = "CLVisitScenarioReplayTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try TestSupport.makeInMemoryContainer()
        let pingRecorder = PingRecorder(modelContainer: container)
        let visitRecorder = VisitRecorder(modelContainer: container)
        let clusterer = StayClusterer(modelContainer: container)
        let classifier = TripClassifier(modelContainer: container)
        let ctx = ModelContext(container)

        ctx.insert(Home(
            label: "Home", latitude: Self.lat, longitude: Self.lon,
            radiusKm: 1, startedAt: at(0, day: -1)))
        let destination = Stay(
            startTime: at(18), endTime: at(21),
            centroidLatitude: Self.lat, centroidLongitude: longitude(40_000),
            h3IndexRes6: "destination", pingCount: 2,
            distanceFromHomeKm: 40, pingIDs: [])
        destination.category = .destination
        let trip = Trip(startDate: destination.startTime)
        ctx.insert(destination)
        ctx.insert(trip)
        destination.trip = trip
        destination.orderInTrip = 0
        try ctx.save()

        await recordPings(pingRecorder, [(at(22, 5), 0)])
        await recordVisit(
            visitRecorder, suiteName: suiteName, arrival: at(22), receivedAt: at(22, 3))
        _ = await clusterer.clusterUnprocessedPings()
        _ = await classifier.classifyAndAssembleTripsWithGates()

        let linkedID = try #require(try visits(container).first?.stayID)
        let firstHome = try #require(try stays(container).first { $0.id == linkedID })
        try expectInterval(firstHome, at(22), at(22, 5))
        #expect(firstHome.pingCount == 1)
        let before = await classifier.assembledTripsForTesting()
        #expect(before.count == 1)
        #expect(before.first?.isComplete == false)

        await recordVisit(
            visitRecorder, suiteName: suiteName, arrival: at(22), departure: at(22, 20),
            receivedAt: at(22, 21))
        _ = await clusterer.clusterUnprocessedPings()
        _ = await classifier.classifyAndAssembleTripsWithGates()

        let secondHome = try #require(try stays(container).first { $0.id == linkedID })
        try expectInterval(secondHome, at(22), at(22, 20))
        let after = await classifier.assembledTripsForTesting()
        let completed = try #require(after.first)
        #expect(completed.isComplete == true)

        let storedTrip = try #require(try ModelContext(container)
            .fetch(FetchDescriptor<Trip>()).first { $0.id == completed.id })
        #expect(storedTrip.endDate == storedTrip.orderedStays.last?.endTime)
    }

    @Test("a multi-day visit received after its pings is trimmed between the neighbouring ping stays")
    func s3PingsFirst() async throws {
        let suiteName = "CLVisitScenarioReplayTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try TestSupport.makeInMemoryContainer()
        let pingRecorder = PingRecorder(modelContainer: container)
        let visitRecorder = VisitRecorder(modelContainer: container)
        let clusterer = StayClusterer(modelContainer: container)
        let times = [at(18), at(8, day: 1), at(8, day: 2), at(9, day: 3)]
        await recordPings(pingRecorder, [
            (times[0], 10_000), (times[1], 0),
            (times[2], 10_000), (times[3], 10_000)])
        _ = await clusterer.clusterUnprocessedPings()
        await recordVisit(
            visitRecorder, suiteName: suiteName, arrival: at(18), departure: at(9, day: 3),
            receivedAt: at(9, 5, day: 3))
        _ = await clusterer.clusterUnprocessedPings()
        let saved = try stays(container)
        #expect(saved.count == 4)
        #expect(try pings(container).map(\.timestamp) == times)
        let linkedID = try #require(try visits(container).first?.stayID)
        let hotel = saved.first { $0.id == linkedID }
        try expectInterval(hotel, at(1, 0, 1, day: 1), at(7, 59, 59, day: 2))
    }

    @Test("a late visit at an existing ping stay extends that stay to the visit's departure")
    func s5() async throws {
        let suiteName = "CLVisitScenarioReplayTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try TestSupport.makeInMemoryContainer()
        let pingRecorder = PingRecorder(modelContainer: container)
        let visitRecorder = VisitRecorder(modelContainer: container)
        let clusterer = StayClusterer(modelContainer: container)
        await recordPings(pingRecorder, [(at(10), 0), (at(14, 30), 10_000)])
        _ = await clusterer.clusterUnprocessedPings()
        await recordVisit(
            visitRecorder, suiteName: suiteName, arrival: at(10, 5), departure: at(11, 55),
            receivedAt: at(15))
        _ = await clusterer.clusterUnprocessedPings()
        let saved = try stays(container)
        try expectInterval(saved[0], at(10), at(11, 55))
        try expectInterval(saved[1], at(14, 30), at(14, 30))
    }

    @Test("a visit with no pings of its own becomes a ping-free stay and adds no hex visit")
    func s6() async throws {
        let suiteName = "CLVisitScenarioReplayTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try TestSupport.makeInMemoryContainer()
        let pingRecorder = PingRecorder(modelContainer: container)
        let visitRecorder = VisitRecorder(modelContainer: container)
        let clusterer = StayClusterer(modelContainer: container)
        await recordPings(pingRecorder, [(at(8, 30), 0), (at(18), 9_000)])
        await recordVisit(
            visitRecorder, suiteName: suiteName, arrival: at(12), departure: at(14),
            receivedAt: at(18, 5), metersEast: 4_000)
        _ = await clusterer.clusterUnprocessedPings()
        let saved = try stays(container)
        #expect(saved.count == 3)
        try expectInterval(saved[0], at(8, 30), at(11, 59))
        try expectInterval(saved[1], at(12), at(14))
        #expect(saved[1].pingCount == 0)
        #expect(saved[1].pingIDs.isEmpty)
        #expect(try ModelContext(container).fetchCount(
            FetchDescriptor<HexVisit>()) == 2)
    }

    @Test("back-to-back visits 464 m apart merge into one stay")
    func s7Forward() async throws {
        let suiteName = "CLVisitScenarioReplayTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try TestSupport.makeInMemoryContainer()
        let pingRecorder = PingRecorder(modelContainer: container)
        let visitRecorder = VisitRecorder(modelContainer: container)
        let clusterer = StayClusterer(modelContainer: container)
        _ = pingRecorder
        await recordVisit(
            visitRecorder, suiteName: suiteName, arrival: at(18), departure: at(20), receivedAt: at(20, 1))
        await recordVisit(
            visitRecorder, suiteName: suiteName, arrival: at(20, 0, 1), departure: at(8, day: 1),
            receivedAt: at(8, 1, day: 1), metersEast: 464)
        _ = await clusterer.clusterUnprocessedPings()
        let saved = try stays(container)
        #expect(saved.count == 1)
        try expectInterval(saved.first, at(18), at(8, day: 1))
    }

    @Test("back-to-back visits 464 m apart merge into one stay when they arrive in reverse order")
    func s7Reverse() async throws {
        let suiteName = "CLVisitScenarioReplayTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try TestSupport.makeInMemoryContainer()
        let pingRecorder = PingRecorder(modelContainer: container)
        let visitRecorder = VisitRecorder(modelContainer: container)
        let clusterer = StayClusterer(modelContainer: container)
        _ = pingRecorder
        await recordVisit(
            visitRecorder, suiteName: suiteName, arrival: at(20, 0, 1), departure: at(8, day: 1),
            receivedAt: at(8, 1, day: 1), metersEast: 464)
        _ = await clusterer.clusterUnprocessedPings()
        await recordVisit(
            visitRecorder, suiteName: suiteName, arrival: at(18), departure: at(20), receivedAt: at(20, 1))
        _ = await clusterer.clusterUnprocessedPings()
        let saved = try stays(container)
        #expect(saved.count == 1)
        try expectInterval(saved.first, at(18), at(8, day: 1))
    }

    @Test("an open visit with no pings becomes a stay ending at its receipt")
    func s8() async throws {
        let suiteName = "CLVisitScenarioReplayTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try TestSupport.makeInMemoryContainer()
        let pingRecorder = PingRecorder(modelContainer: container)
        let visitRecorder = VisitRecorder(modelContainer: container)
        let clusterer = StayClusterer(modelContainer: container)
        _ = pingRecorder
        await recordVisit(
            visitRecorder, suiteName: suiteName, arrival: at(9), receivedAt: at(9, 7))
        #expect(await clusterer.clusterUnprocessedPings() == 1)
        try expectInterval(try stays(container).first, at(9), at(9, 7))
    }

    @Test("an open coarse visit and its repeated closed update stay one stay and one visit at the refined position")
    func s13() async throws {
        let suiteName = "CLVisitScenarioReplayTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try TestSupport.makeInMemoryContainer()
        let pingRecorder = PingRecorder(modelContainer: container)
        let visitRecorder = VisitRecorder(modelContainer: container)
        let clusterer = StayClusterer(modelContainer: container)
        _ = pingRecorder
        await recordVisit(
            visitRecorder, suiteName: suiteName, arrival: at(12), receivedAt: at(12, 5), accuracy: 20)
        _ = await clusterer.clusterUnprocessedPings()
        await recordVisit(
            visitRecorder, suiteName: suiteName, arrival: at(12), departure: at(13),
            receivedAt: at(13, 1), metersEast: 500, accuracy: 5)
        _ = await clusterer.clusterUnprocessedPings()
        await recordVisit(
            visitRecorder, suiteName: suiteName, arrival: at(12), departure: at(13),
            receivedAt: at(13, 2), metersEast: 500, accuracy: 5)
        #expect(await clusterer.clusterUnprocessedPings() == 0)
        let saved = try stays(container)
        #expect(saved.count == 1)
        #expect(try visits(container).count == 1)
        try expectInterval(saved.first, at(12), at(13))
        #expect(saved.first?.centroidLongitude == longitude(500))
    }

    @Test("a closed visit with no open copy before it makes one stay at its position")
    func s13ClosedFirst() async throws {
        let suiteName = "CLVisitScenarioReplayTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try TestSupport.makeInMemoryContainer()
        let pingRecorder = PingRecorder(modelContainer: container)
        let visitRecorder = VisitRecorder(modelContainer: container)
        let clusterer = StayClusterer(modelContainer: container)
        _ = pingRecorder
        await recordVisit(
            visitRecorder, suiteName: suiteName, arrival: at(12), departure: at(13),
            receivedAt: at(13, 1), metersEast: 500, accuracy: 5)
        #expect(await clusterer.clusterUnprocessedPings() == 1)
        let saved = try stays(container)
        #expect(saved.count == 1)
        try expectInterval(saved.first, at(12), at(13))
        #expect(saved.first?.centroidLongitude == longitude(500))
    }

    @Test("a visit pulls the preceding ping stay back to end just before its arrival")
    func neighbourPullback() async throws {
        let suiteName = "CLVisitScenarioReplayTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try TestSupport.makeInMemoryContainer()
        let pingRecorder = PingRecorder(modelContainer: container)
        let visitRecorder = VisitRecorder(modelContainer: container)
        let clusterer = StayClusterer(modelContainer: container)
        await recordPings(
            pingRecorder, [(at(17), 0), (at(18), 0), (at(22), 4_000)])
        _ = await clusterer.clusterUnprocessedPings()
        await recordVisit(
            visitRecorder, suiteName: suiteName, arrival: at(19), departure: at(23),
            receivedAt: at(23, 1), metersEast: 4_000)
        _ = await clusterer.clusterUnprocessedPings()
        let saved = try stays(container)
        #expect(saved.count == 2)
        try expectInterval(saved[0], at(17), at(18, 59))
        try expectInterval(saved[1], at(19), at(23))
    }
}
