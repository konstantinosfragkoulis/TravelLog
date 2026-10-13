//
//  ForegroundLocationStreamReplayTests.swift
//  TravelLogTests
//
//  Decision instrument for a foreground continuous-location channel.
//  Exercises the REAL live PingRecorder dedup and StayClusterer with:
//    (a) 10 minutes stationary at 1 Hz
//    (b) 45 minutes moving at nominally 60 km/h at 1 Hz
//
//  The production thinner is checked against a pure reference policy.
//  Open-South-Pacific coordinates keep the existing resolver offline-only.
//

import Testing
import Foundation
import SwiftData
import CoreLocation
@testable import TravelLog

@MainActor
@Suite("Foreground location stream replay")
struct ForegroundLocationStreamReplayTests {

    private static let base = Date(timeIntervalSince1970: 1_700_000_000)
    private static let latitude = 0.0
    private static let originLongitude = -140.0
    private static let speedMetersPerSecond = 60_000.0 / 3_600.0

    private static let metersPerLongitudeDegree = CLLocation(
        latitude: latitude,
        longitude: originLongitude
    ).distance(from: CLLocation(
        latitude: latitude,
        longitude: originLongitude + 1
    ))

    private struct StaySnapshot {
        let startTime: Date
        let endTime: Date
        let durationMinutes: Int
        let pingCount: Int
        let category: StayCategory
    }

    /// Proposed pre-recorder policy. Production must run the shared stale /
    /// invalid-altitude filter before this stream-specific accuracy/thinning step.
    private struct ReferenceThinner {
        private var lastKept: CLLocation?

        mutating func shouldKeep(_ candidate: CLLocation) -> Bool {
            guard candidate.horizontalAccuracy >= 0,
                  candidate.horizontalAccuracy <= 100 else {
                return false
            }

            guard let previous = lastKept else {
                lastKept = candidate
                return true
            }

            let elapsed = candidate.timestamp.timeIntervalSince(previous.timestamp)
            guard elapsed >= 0 else { return false }

            if elapsed >= 90 || candidate.distance(from: previous) >= 250 {
                lastKept = candidate
                return true
            }

            return false
        }
    }

    private func makeLocation(
        second: Int,
        metersEast: Double,
        speed: Double
    ) -> CLLocation {
        let longitude = Self.originLongitude
            + metersEast / Self.metersPerLongitudeDegree

        return CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude: Self.latitude,
                longitude: longitude
            ),
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: speed > 0 ? 90 : -1,
            speed: speed,
            timestamp: Self.base.addingTimeInterval(TimeInterval(second))
        )
    }

    private func stationaryLocations() -> [CLLocation] {
        (0..<600).map {
            makeLocation(second: $0, metersEast: 0, speed: 0)
        }
    }

    private func carLocations() -> [CLLocation] {
        (0..<2_700).map { second in
            // Nominal 60 km/h. The 1 cm increment every six seconds makes
            // the strict "< 100 m" and "> 3,000 m" branches deterministic
            // without materially changing the 45 km trace.
            let nominalMeters = Double(second) * Self.speedMetersPerSecond
            let comparisonGuardMeters = Double(second / 6) * 0.01
            return makeLocation(
                second: second,
                metersEast: nominalMeters + comparisonGuardMeters,
                speed: Self.speedMetersPerSecond
            )
        }
    }

    private func referenceThinned(_ input: [CLLocation]) -> [CLLocation] {
        var policy = ReferenceThinner()
        var output: [CLLocation] = []
        output.reserveCapacity(input.count)

        for location in input {
            if policy.shouldKeep(location) {
                output.append(location)
            }
        }
        return output
    }

    private func thinned(_ input: [CLLocation]) -> [CLLocation] {
        var policy = ForegroundLocationThinner()
        var output: [CLLocation] = []
        output.reserveCapacity(input.count)

        for location in input where policy.shouldKeep(location) {
            output.append(location)
        }
        return output
    }

    private func pingTimestamps(
        in container: ModelContainer
    ) throws -> [Date] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<LocationPing>(
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )).map(\.timestamp)
    }

    private func staySnapshots(
        in container: ModelContainer
    ) throws -> [StaySnapshot] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<Stay>(
            sortBy: [SortDescriptor(\.startTime, order: .forward)]
        )).map {
            StaySnapshot(
                startTime: $0.startTime,
                endTime: $0.endTime,
                durationMinutes: $0.durationMinutes,
                pingCount: $0.pingCount,
                category: $0.category
            )
        }
    }

    private func tripCount(
        in container: ModelContainer
    ) throws -> Int {
        let context = ModelContext(container)
        return try context.fetchCount(FetchDescriptor<Trip>())
    }

    @Test("raw 10-minute stationary stream persists 10 pings and forms one 9-minute home stay")
    func rawStationaryReplay() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let seedContext = ModelContext(container)
        seedContext.insert(Home(
            label: "Synthetic home",
            latitude: Self.latitude,
            longitude: Self.originLongitude,
            radiusKm: 1,
            startedAt: Self.base.addingTimeInterval(-1)
        ))
        try seedContext.save()

        let recorder = PingRecorder(modelContainer: container)
        await recorder.processLocations(stationaryLocations().map {
            LiveLocationCandidate($0, source: .liveSLC)
        }, defaults: TestSupport.liveFloorFreeDefaults)

        let expectedTimes = stride(from: 0, through: 549, by: 61)
            .map { Self.base.addingTimeInterval(TimeInterval($0)) }
        #expect(try pingTimestamps(in: container) == expectedTimes)

        let clusterer = StayClusterer(modelContainer: container)
        #expect(await clusterer.clusterUnprocessedPings() == 1)

        let stays = try staySnapshots(in: container)
        #expect(stays.count == 1)
        let stay = try #require(stays.first)
        #expect(stay.startTime == Self.base)
        #expect(stay.endTime == Self.base.addingTimeInterval(549))
        #expect(stay.durationMinutes == 9)
        #expect(stay.pingCount == 10)

        let classifier = TripClassifier(modelContainer: container)
        _ = await classifier.classifyAndAssembleTripsWithGates(
            reclassifyRecentStays: false,
            maxStaysPerCall: nil
        )

        let classified = try staySnapshots(in: container)
        #expect(classified.count == 1)
        #expect(classified.first?.category == .home)
        #expect(try tripCount(in: container) == 0)
    }

    @Test("raw 45-minute 60-km/h stream persists 450 pings, forms 8 short transit stays, and no trip")
    func rawCarReplay() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = PingRecorder(modelContainer: container)

        await recorder.processLocations(carLocations().map {
            LiveLocationCandidate($0, source: .liveSLC)
        }, defaults: TestSupport.liveFloorFreeDefaults)

        let pings = try pingTimestamps(in: container)
        #expect(pings.count == 450)
        #expect(pings.first == Self.base)
        #expect(pings.last == Self.base.addingTimeInterval(2_694))

        let clusterer = StayClusterer(modelContainer: container)
        #expect(await clusterer.clusterUnprocessedPings() == 8)

        let stays = try staySnapshots(in: container)
        #expect(stays.count == 8)
        #expect(stays.map(\.pingCount).reduce(0, +) == 450)
        #expect(stays.allSatisfy { $0.durationMinutes <= 20 })

        let classifier = TripClassifier(modelContainer: container)
        _ = await classifier.classifyAndAssembleTripsWithGates(
            reclassifyRecentStays: false,
            maxStaysPerCall: nil
        )

        let classified = try staySnapshots(in: container)
        #expect(classified.count == 8)
        #expect(classified.allSatisfy { $0.category == .transit })
        #expect(try tripCount(in: container) == 0)
    }

    @Test("250-m-or-90-s pre-thinning produces 7 and 180 pings while preserving 1 and 8 stays")
    func proposedThinningReplay() async throws {
        let stationaryInput = stationaryLocations()
        let carInput = carLocations()
        let stationary = thinned(stationaryInput)
        let car = thinned(carInput)

        #expect(stationary.count == 7)
        #expect(car.count == 180)
        #expect(stationary.map(\.timestamp)
                == referenceThinned(stationaryInput).map(\.timestamp))
        #expect(car.map(\.timestamp)
                == referenceThinned(carInput).map(\.timestamp))

        let stationaryContainer = try TestSupport.makeInMemoryContainer()
        let stationaryRecorder = PingRecorder(
            modelContainer: stationaryContainer
        )
        await stationaryRecorder.processLocations(stationary.map {
            LiveLocationCandidate($0, source: .liveSLC)
        }, defaults: TestSupport.liveFloorFreeDefaults)

        #expect(try pingTimestamps(in: stationaryContainer).count == 7)
        let stationaryClusterer = StayClusterer(
            modelContainer: stationaryContainer
        )
        #expect(
            await stationaryClusterer.clusterUnprocessedPings() == 1
        )

        let carContainer = try TestSupport.makeInMemoryContainer()
        let carRecorder = PingRecorder(modelContainer: carContainer)
        await carRecorder.processLocations(car.map {
            LiveLocationCandidate($0, source: .liveSLC)
        }, defaults: TestSupport.liveFloorFreeDefaults)

        #expect(try pingTimestamps(in: carContainer).count == 180)
        let carClusterer = StayClusterer(modelContainer: carContainer)
        #expect(await carClusterer.clusterUnprocessedPings() == 8)

        let carStays = try staySnapshots(in: carContainer)
        #expect(carStays.count == 8)
        #expect(carStays.map(\.pingCount).reduce(0, +) == 180)
    }
}
