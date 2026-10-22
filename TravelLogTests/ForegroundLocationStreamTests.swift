//
//  ForegroundLocationStreamTests.swift
//  TravelLogTests
//

import CoreLocation
import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Foreground location stream")
struct ForegroundLocationStreamTests {

    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func location(
        timestamp: Date? = nil,
        horizontalAccuracy: Double = 10,
        altitude: Double = 0,
        verticalAccuracy: Double = 10,
        metersEast: Double = 0
    ) -> CLLocation {
        let origin = CLLocation(latitude: 0, longitude: 0)
        let metresPerLongitudeDegree = origin.distance(from: CLLocation(
            latitude: 0, longitude: 1))
        return CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude: 0,
                longitude: metersEast / metresPerLongitudeDegree),
            altitude: altitude,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: verticalAccuracy,
            course: -1,
            speed: -1,
            timestamp: timestamp ?? Self.base)
    }

    private func candidate(
        timestamp: Date,
        latitude: Double,
        longitude: Double,
        source: DataSource
    ) -> LiveLocationCandidate {
        LiveLocationCandidate(
            CLLocation(
                coordinate: CLLocationCoordinate2D(
                    latitude: latitude, longitude: longitude),
                altitude: 0,
                horizontalAccuracy: 10,
                verticalAccuracy: 10,
                course: -1,
                speed: -1,
                timestamp: timestamp
            ),
            source: source
        )
    }

    private func h3Index(
        latitude: Double, longitude: Double
    ) throws -> String {
        try #require(H3Service.cellIndex(
            latitude: latitude, longitude: longitude))
    }

    private func fetchPings(
        in container: ModelContainer
    ) throws -> [LocationPing] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<LocationPing>(
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]))
    }

    private func fetchPing(
        id: UUID, in container: ModelContainer
    ) throws -> LocationPing {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<LocationPing>(
            predicate: #Predicate { $0.id == id })
        return try #require(try context.fetch(descriptor).first)
    }

    @Test
    func sharedValidityPreservesSLCBoundaries() {
        let service = LocationService.shared

        #expect(service.isValidLiveLocation(location(
            timestamp: Self.base.addingTimeInterval(-299.999)), now: Self.base))
        #expect(!service.isValidLiveLocation(location(
            timestamp: Self.base.addingTimeInterval(-300)), now: Self.base))
        #expect(!service.isValidLiveLocation(location(
            timestamp: Self.base.addingTimeInterval(300)), now: Self.base))
        #expect(!service.isValidLiveLocation(location(
            horizontalAccuracy: -1), now: Self.base))
        #expect(service.isValidLiveLocation(location(
            horizontalAccuracy: 0), now: Self.base))
        #expect(service.isValidLiveLocation(location(
            horizontalAccuracy: 4_999.999), now: Self.base))
        #expect(!service.isValidLiveLocation(location(
            horizontalAccuracy: 5_000), now: Self.base))

        #expect(service.isValidLiveLocation(location(
            altitude: 5_000, verticalAccuracy: 0), now: Self.base))
        #expect(!service.isValidLiveLocation(location(
            altitude: 5_000.001, verticalAccuracy: 0), now: Self.base))
        #expect(!service.isValidLiveLocation(location(
            altitude: 5_000.001, verticalAccuracy: 200), now: Self.base))
        #expect(service.isValidLiveLocation(location(
            altitude: 5_000.001, verticalAccuracy: -1), now: Self.base))
        #expect(service.isValidLiveLocation(location(
            altitude: 5_000.001, verticalAccuracy: 200.001), now: Self.base))
    }

    @Test
    func foregroundAccuracyAcceptsExactly100Metres() {
        let service = LocationService.shared
        let exact = location(horizontalAccuracy: 100)
        let over = location(horizontalAccuracy: 100.001)
        #expect(service.isValidLiveLocation(exact, now: Self.base))
        #expect(service.isValidLiveLocation(over, now: Self.base))

        var exactPolicy = ForegroundLocationThinner()
        var overPolicy = ForegroundLocationThinner()
        let exactAccepted = exactPolicy.shouldKeep(exact)
        let overAccepted = overPolicy.shouldKeep(over)
        #expect(exactAccepted)
        #expect(!overAccepted)
    }

    @Test
    func thinnerKeepsFirstThenInclusive250MetresOr90Seconds() {
        #expect(!ForegroundLocationThinner.meetsSpacing(
            distanceMeters: 249.999, elapsedSeconds: 89.999))
        #expect(ForegroundLocationThinner.meetsSpacing(
            distanceMeters: 250, elapsedSeconds: 0))
        #expect(ForegroundLocationThinner.meetsSpacing(
            distanceMeters: 0, elapsedSeconds: 90))

        var policy = ForegroundLocationThinner()
        let keptFirst = policy.shouldKeep(location())
        let keptInsideBothThresholds = policy.shouldKeep(location(
            timestamp: Self.base.addingTimeInterval(89), metersEast: 249))
        let keptAtTimeBoundary = policy.shouldKeep(location(
            timestamp: Self.base.addingTimeInterval(90)))
        #expect(keptFirst)
        #expect(!keptInsideBothThresholds)
        #expect(keptAtTimeBoundary)

        policy.reset()
        let keptAfterReset = policy.shouldKeep(location())
        #expect(keptAfterReset)
    }

    @Test
    func outOfOrderFixDoesNotAdvanceLastKept() {
        var policy = ForegroundLocationThinner()
        let keptFirst = policy.shouldKeep(location(
            timestamp: Self.base.addingTimeInterval(100)))
        let keptOutOfOrder = policy.shouldKeep(location(
            timestamp: Self.base.addingTimeInterval(99), metersEast: 500))
        let keptBeforeOriginalDeadline = policy.shouldKeep(location(
            timestamp: Self.base.addingTimeInterval(189)))
        let keptAtOriginalDeadline = policy.shouldKeep(location(
            timestamp: Self.base.addingTimeInterval(190)))
        #expect(keptFirst)
        #expect(!keptOutOfOrder)
        #expect(!keptBeforeOriginalDeadline)
        #expect(keptAtOriginalDeadline)
    }

    @Test
    func batchPolicyFlushesAtEightOrThirtySeconds() {
        #expect(!ForegroundLocationStreamController.shouldFlush(
            pendingCount: 0,
            pendingSince: Self.base,
            now: Self.base.addingTimeInterval(30)))
        #expect(!ForegroundLocationStreamController.shouldFlush(
            pendingCount: 7,
            pendingSince: Self.base,
            now: Self.base.addingTimeInterval(29.999)))
        #expect(ForegroundLocationStreamController.shouldFlush(
            pendingCount: 7,
            pendingSince: Self.base,
            now: Self.base.addingTimeInterval(30)))
        #expect(ForegroundLocationStreamController.shouldFlush(
            pendingCount: 8,
            pendingSince: nil,
            now: Self.base))

        var pending = Array(0..<ForegroundLocationStreamController.pendingCapacity)
        let dropped = ForegroundLocationStreamController.appendPending(
            8, to: &pending)
        #expect(dropped)
        #expect(pending == Array(1...8))
        #expect(pending.count == ForegroundLocationStreamController.pendingCapacity)
    }

    @Test
    func startDecisionUsesFallbackWithoutPrompting() {
        typealias Controller = ForegroundLocationStreamController
        #expect(Controller.startDecision(
            applicationIsActive: true,
            hasPermission: false,
            accuracyAuthorization: .fullAccuracy,
            lowPowerModeEnabled: false,
            thermalState: .nominal) == .noOp)
        #expect(Controller.startDecision(
            applicationIsActive: false,
            hasPermission: true,
            accuracyAuthorization: .fullAccuracy,
            lowPowerModeEnabled: false,
            thermalState: .nominal) == .noOp)

        let fallbackInputs: [(CLAccuracyAuthorization, Bool, ProcessInfo.ThermalState)] = [
            (.reducedAccuracy, false, .nominal),
            (.fullAccuracy, true, .nominal),
            (.fullAccuracy, false, .serious),
            (.fullAccuracy, false, .critical),
        ]
        for input in fallbackInputs {
            #expect(Controller.startDecision(
                applicationIsActive: true,
                hasPermission: true,
                accuracyAuthorization: input.0,
                lowPowerModeEnabled: input.1,
                thermalState: input.2) == .requestFallback)
        }

        #expect(Controller.startDecision(
            applicationIsActive: true,
            hasPermission: true,
            accuracyAuthorization: .fullAccuracy,
            lowPowerModeEnabled: false,
            thermalState: .fair) == .startStream)
    }

    @Test
    func fallbackIsOncePerActivationWithSixtySecondGuard() {
        typealias Controller = ForegroundLocationStreamController
        #expect(Controller.fallbackMinimumIntervalSeconds == 60)
        #expect(Controller.shouldRequestFallback(
            alreadyRequestedThisActivation: false,
            lastRequestedAt: nil,
            now: Self.base))
        #expect(!Controller.shouldRequestFallback(
            alreadyRequestedThisActivation: true,
            lastRequestedAt: nil,
            now: Self.base))
        #expect(!Controller.shouldRequestFallback(
            alreadyRequestedThisActivation: false,
            lastRequestedAt: Self.base,
            now: Self.base.addingTimeInterval(59.999)))
        #expect(Controller.shouldRequestFallback(
            alreadyRequestedThisActivation: false,
            lastRequestedAt: Self.base,
            now: Self.base.addingTimeInterval(60)))
    }

    @Test
    func staleActivationGenerationCannotKeepOrFlush() {
        let staleAccepted = ForegroundLocationStreamController.shouldAcceptUpdate(
            capturedGeneration: 41,
            currentGeneration: 42,
            applicationIsActive: true)
        var pending = [0]
        var requestedFallback = false
        if staleAccepted {
            pending.append(1)
            requestedFallback = true
        }
        #expect(!staleAccepted)
        #expect(pending == [0])
        #expect(!requestedFallback)
        #expect(!ForegroundLocationStreamController.shouldAcceptUpdate(
            capturedGeneration: 42,
            currentGeneration: 42,
            applicationIsActive: false))
        #expect(ForegroundLocationStreamController.shouldAcceptUpdate(
            capturedGeneration: 42,
            currentGeneration: 42,
            applicationIsActive: true))
    }

    @Test
    func fastPathDelayIsImmediateThenAtLeastThreeMinutes() {
        #expect(AppDelegate.foregroundFastPathMinimumIntervalSeconds == 180)
        #expect(AppDelegate.foregroundFastPathDelay(
            lastCompletedAt: nil, now: Self.base) == 0)
        #expect(AppDelegate.foregroundFastPathDelay(
            lastCompletedAt: Self.base,
            now: Self.base.addingTimeInterval(60)) == 120)
        #expect(AppDelegate.foregroundFastPathDelay(
            lastCompletedAt: Self.base,
            now: Self.base.addingTimeInterval(179.999)) > 0)
        #expect(AppDelegate.foregroundFastPathDelay(
            lastCompletedAt: Self.base,
            now: Self.base.addingTimeInterval(180)) == 0)
    }

    @Test
    func processLocationsPersistsForegroundStreamSource() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = PingRecorder(modelContainer: container)

        await recorder.processLocations([candidate(
            timestamp: Self.base,
            latitude: 0,
            longitude: -140,
            source: .foregroundStream,
        )], defaults: TestSupport.liveFloorFreeDefaults)

        let ping = try #require(try fetchPings(in: container).first)
        #expect(ping.sourceRaw == "foregroundStream")
    }

    @Test
    func globalLiveDedupKeepsFirstWriterSource() async throws {
        let sourceOrders: [(first: DataSource, second: DataSource)] = [
            (.foregroundStream, .liveSLC),
            (.liveSLC, .foregroundStream),
        ]

        for sourceOrder in sourceOrders {
            let container = try TestSupport.makeInMemoryContainer()
            let recorder = PingRecorder(modelContainer: container)
            let first = candidate(
                timestamp: Self.base,
                latitude: 0,
                longitude: -140,
                source: sourceOrder.first)
            let second = candidate(
                timestamp: Self.base.addingTimeInterval(1),
                latitude: 0,
                longitude: -140,
                source: sourceOrder.second)

            await recorder.processLocations([first, second], defaults: TestSupport.liveFloorFreeDefaults)

            let pings = try fetchPings(in: container)
            #expect(pings.count == 1)
            #expect(pings.first?.source == sourceOrder.first)
        }
    }

    @Test
    func restoreLiveH3CursorIncludesForegroundStreamAndExcludesImports() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let slc = (latitude: 0.0, longitude: -140.0)
        let foreground = (latitude: 0.0, longitude: -130.0)
        let imported = (latitude: 0.0, longitude: -120.0)
        let slcH3 = try h3Index(latitude: slc.latitude, longitude: slc.longitude)
        let foregroundH3 = try h3Index(
            latitude: foreground.latitude, longitude: foreground.longitude)
        let importedH3 = try h3Index(
            latitude: imported.latitude, longitude: imported.longitude)

        context.insert(LocationPing(
            timestamp: Self.base,
            latitude: slc.latitude,
            longitude: slc.longitude,
            horizontalAccuracy: 10,
            h3IndexRes6: slcH3,
            source: .liveSLC))
        context.insert(LocationPing(
            timestamp: Self.base.addingTimeInterval(60),
            latitude: foreground.latitude,
            longitude: foreground.longitude,
            horizontalAccuracy: 10,
            h3IndexRes6: foregroundH3,
            source: .foregroundStream))
        context.insert(LocationPing(
            timestamp: Self.base.addingTimeInterval(120),
            latitude: imported.latitude,
            longitude: imported.longitude,
            horizontalAccuracy: 10,
            h3IndexRes6: importedH3,
            source: .photoImport))
        context.insert(HexVisit(
            h3Index: foregroundH3,
            firstVisited: Self.base.addingTimeInterval(60),
            centerLatitude: foreground.latitude,
            centerLongitude: foreground.longitude))
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        await recorder.restoreLastH3Index()
        await recorder.processLocations([candidate(
            timestamp: Self.base.addingTimeInterval(300),
            latitude: foreground.latitude,
            longitude: foreground.longitude,
            source: .liveSLC,
        )], defaults: TestSupport.liveFloorFreeDefaults)

        let readContext = ModelContext(container)
        let descriptor = FetchDescriptor<HexVisit>(
            predicate: #Predicate { $0.h3Index == foregroundH3 })
        let visit = try #require(try readContext.fetch(descriptor).first)
        #expect(visit.visitCount == 1)
    }

    @Test
    func foregroundOnlyBatchDoesNotDrainSLCGeocodeBacklog() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let backlog = LocationPing(
            timestamp: Self.base,
            latitude: 37.9838,
            longitude: 23.7275,
            horizontalAccuracy: 10,
            h3IndexRes6: try h3Index(latitude: 37.9838, longitude: 23.7275),
            source: .photoImport)
        let backlogID = backlog.id
        context.insert(backlog)
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        await recorder.processLocations([candidate(
            timestamp: Self.base.addingTimeInterval(600),
            latitude: 0,
            longitude: -140,
            source: .foregroundStream,
        )], defaults: TestSupport.liveFloorFreeDefaults)
        #expect(try fetchPing(id: backlogID, in: container).isGeocoded == false)

        await recorder.processLocations([candidate(
            timestamp: Self.base.addingTimeInterval(1_200),
            latitude: 0,
            longitude: -130,
            source: .liveSLC,
        )], defaults: TestSupport.liveFloorFreeDefaults)
        #expect(try fetchPing(id: backlogID, in: container).isGeocoded)
    }
}
