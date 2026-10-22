//
//  LiveIngestTouchingTests.swift
//  TravelLogTests
//
//  Pins the store changes the live ping unit and the foreground fast path
//  publish: what their saves wrote, taken before each save, instead of a
//  static declaration. A same-cell ping batch no longer reports stays or hex
//  visits, a home stay extension no longer reports a trip, and the SLC geocode
//  lane reports the trip whose title it invalidates.
//

import CoreLocation
import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Live ingest store changes")
struct LiveIngestTouchingTests {

    private let base = Date(timeIntervalSince1970: 1_721_772_800)
    private let athens = (latitude: 37.9838, longitude: 23.7275)

    private func candidate(
        at timestamp: Date, latitude: Double, longitude: Double, source: DataSource
    ) -> LiveLocationCandidate {
        LiveLocationCandidate(
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10,
                course: -1, speed: -1, timestamp: timestamp),
            source: source)
    }

    private func ping(at date: Date) -> LocationPing {
        LocationPing(
            timestamp: date, latitude: athens.latitude, longitude: athens.longitude,
            horizontalAccuracy: 10, h3IndexRes6: "touching", source: .liveSLC)
    }

    private func stay(at date: Date) -> Stay {
        Stay(
            startTime: date, endTime: date.addingTimeInterval(3600),
            centroidLatitude: athens.latitude, centroidLongitude: athens.longitude,
            h3IndexRes6: "touching", pingCount: 2,
            distanceFromHomeKm: 0, pingIDs: [])
    }

    // MARK: - Live ping unit

    @Test("a same-cell foreground batch reports only pings")
    func sameCellForegroundBatchReportsOnlyPings() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = PingRecorder(modelContainer: container)
        // About 150 m north of the first fix.
        let nearby = (latitude: athens.latitude + 0.00135, longitude: athens.longitude)
        let firstCell = try #require(H3Service.cellIndex(
            latitude: athens.latitude, longitude: athens.longitude))
        let secondCell = try #require(H3Service.cellIndex(
            latitude: nearby.latitude, longitude: nearby.longitude))
        try #require(firstCell == secondCell)

        let first = await recorder.processLocations([candidate(
            at: base, latitude: athens.latitude, longitude: athens.longitude,
            source: .foregroundStream)], defaults: TestSupport.liveFloorFreeDefaults)
        #expect(first.isSuperset(of: [.locationPing, .hexVisit]))

        let second = await recorder.processLocations([candidate(
            at: base.addingTimeInterval(300), latitude: nearby.latitude,
            longitude: nearby.longitude, source: .foregroundStream)], defaults: TestSupport.liveFloorFreeDefaults)
        #expect(second == .locationPing)
    }

    @Test("a duplicate batch reports nothing")
    func duplicateBatchReportsNothing() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = PingRecorder(modelContainer: container)
        let fix = candidate(
            at: base, latitude: athens.latitude, longitude: athens.longitude,
            source: .foregroundStream)
        let first = await recorder.processLocations([fix], defaults: TestSupport.liveFloorFreeDefaults)
        #expect(first.contains(.locationPing))
        let second = await recorder.processLocations([fix], defaults: TestSupport.liveFloorFreeDefaults)
        #expect(second.isEmpty)
    }

    @Test("the SLC geocode lane reports the trip whose title it invalidates")
    func slcTitleInvalidationReportsTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let backlog = LocationPing(
            timestamp: base, latitude: athens.latitude, longitude: athens.longitude,
            horizontalAccuracy: 10,
            h3IndexRes6: try #require(H3Service.cellIndex(
                latitude: athens.latitude, longitude: athens.longitude)))
        let trip = Trip(startDate: base)
        trip.aiGeneratedTitle = "Old"
        let tripStay = stay(at: base)
        tripStay.pingIDs = [backlog.id]
        context.insert(backlog)
        context.insert(trip)
        context.insert(tripStay)
        tripStay.trip = trip
        try context.save()
        #expect(tripStay.locality == nil && !backlog.isGeocoded)

        let recorder = PingRecorder(modelContainer: container)
        let changes = await recorder.processLocations([candidate(
            at: base.addingTimeInterval(3600), latitude: athens.latitude,
            longitude: athens.longitude, source: .liveSLC)], defaults: TestSupport.liveFloorFreeDefaults)
        #expect(changes.isSuperset(of: [.locationPing, .stay, .trip]))

        let verification = ModelContext(container)
        let savedTrip = try #require(try verification.fetch(FetchDescriptor<Trip>()).first)
        #expect(savedTrip.aiGeneratedTitle == nil)
        let savedStay = try #require(try verification.fetch(FetchDescriptor<Stay>()).first)
        #expect(savedStay.locality != nil)
    }

    // MARK: - Foreground fast path clustering

    @Test("extending a stay without a trip reports no trip, then settles")
    func homeStayExtensionDoesNotReportTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(stay(at: base))
        context.insert(ping(at: base.addingTimeInterval(7200)))
        try context.save()
        let clusterer = StayClusterer(modelContainer: container)
        let outcome = await clusterer.clusterUnprocessedPingsReportingChanges()
        #expect(outcome.changes == [.stay, .locationPing])
        let settled = await clusterer.clusterUnprocessedPingsReportingChanges()
        #expect(settled.changes.isEmpty)
    }

    @Test("extending a stay with a trip reports the trip")
    func tripStayExtensionReportsTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: base)
        trip.aiGeneratedTitle = "Athens"
        let tripStay = stay(at: base)
        context.insert(trip)
        context.insert(tripStay)
        tripStay.trip = trip
        context.insert(ping(at: base.addingTimeInterval(7200)))
        try context.save()
        let outcome = await StayClusterer(modelContainer: container)
            .clusterUnprocessedPingsReportingChanges()
        #expect(outcome.changes.isSuperset(of: [.stay, .locationPing, .trip]))
    }

    @Test("Visit-only reconciliation reports visits and stays, not pings")
    func visitOnlyReconciliationReportsVisit() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(Visit(
            arrivalDate: base, departureDate: base.addingTimeInterval(7200),
            latitude: athens.latitude, longitude: athens.longitude, horizontalAccuracy: 5,
            receivedAt: base.addingTimeInterval(7200)))
        try context.save()
        let outcome = await StayClusterer(modelContainer: container)
            .clusterUnprocessedPingsReportingChanges()
        #expect(outcome.changes.isSuperset(of: [.visit, .stay]))
        #expect(!outcome.changes.contains(.locationPing))
    }

    #if DEBUG
    @Test("a failed cluster save fails open to every type clustering writes")
    func failedClusterSaveReportsAttemptedTypes() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(ping(at: base))
        try context.save()
        let outcome = await StayClusterer(modelContainer: container)
            .clusterUnprocessedPingsReportingChanges(beforeSave: {
                throw CocoaError(.fileWriteUnknown)
            })
        #expect(outcome.failed)
        #expect(outcome.changes.isSuperset(of: StayClusterer.clusteringWrites))
    }
    #endif
}
