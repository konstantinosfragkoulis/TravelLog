//
//  VisitRecorderTests.swift
//  TravelLogTests
//

import CoreLocation
import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Visit recorder", .serialized)
struct VisitRecorderTests {

    private nonisolated static let base = Date(timeIntervalSinceReferenceDate: 786_089_600)

    private struct StubVisit: VisitEventSource {
        let coordinate: CLLocationCoordinate2D
        let horizontalAccuracy: CLLocationAccuracy
        let arrivalDate: Date
        let departureDate: Date
    }

    private func observation(
        arrival: Date = Self.base,
        departure: Date? = nil,
        receivedAt: Date = Self.base.addingTimeInterval(100),
        latitude: Double = 37.9838,
        longitude: Double = 23.7275,
        accuracy: Double = 25
    ) -> VisitObservation {
        VisitObservation(
            source: StubVisit(
                coordinate: CLLocationCoordinate2D(
                    latitude: latitude, longitude: longitude),
                horizontalAccuracy: accuracy,
                arrivalDate: arrival,
                departureDate: departure ?? .distantFuture),
            receivedAt: receivedAt)
    }

    private func visits(in container: ModelContainer) throws -> [Visit] {
        try ModelContext(container).fetch(FetchDescriptor<Visit>())
    }

    @Test func closedInsert() async throws {
        let suiteName = "VisitRecorderTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = VisitRecorder(modelContainer: container)
        let departure = Self.base.addingTimeInterval(60)
        let receipt = Self.base.addingTimeInterval(120)

        await recorder.record(observation(
            departure: departure, receivedAt: receipt,
            latitude: 39.6628, longitude: 20.8612, accuracy: 18), defaults: defaults)

        let row = try #require(try visits(in: container).first)
        #expect(try visits(in: container).count == 1)
        #expect(row.arrivalDate == Self.base)
        #expect(row.departureDate == departure)
        #expect(row.latitude == 39.6628)
        #expect(row.longitude == 20.8612)
        #expect(row.horizontalAccuracy == 18)
        #expect(row.receivedAt == receipt)
        #expect(row.stayID == nil)
        #expect(!row.isProcessed)
    }

    @Test func openThenClosed() async throws {
        let suiteName = "VisitRecorderTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = VisitRecorder(modelContainer: container)
        let departure = Self.base.addingTimeInterval(60)
        let secondReceipt = Self.base.addingTimeInterval(130)

        await recorder.record(observation(), defaults: defaults)
        await recorder.record(observation(
            departure: departure, receivedAt: secondReceipt), defaults: defaults)

        let rows = try visits(in: container)
        #expect(rows.count == 1)
        #expect(rows.first?.departureDate == departure)
        #expect(rows.first?.receivedAt == secondReceipt)
        #expect(rows.first?.isProcessed == false)
    }

    @Test func exactClosedRedelivery() async throws {
        let suiteName = "VisitRecorderTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = VisitRecorder(modelContainer: container)
        let departure = Self.base.addingTimeInterval(60)
        let firstReceipt = Self.base.addingTimeInterval(100)

        await recorder.record(observation(
            departure: departure, receivedAt: firstReceipt), defaults: defaults)
        await recorder.record(observation(
            departure: departure,
            receivedAt: Self.base.addingTimeInterval(200)), defaults: defaults)

        let rows = try visits(in: container)
        #expect(rows.count == 1)
        #expect(rows.first?.receivedAt == firstReceipt)
    }

    @Test func accuracyReplacement() async throws {
        let suiteName = "VisitRecorderTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = VisitRecorder(modelContainer: container)
        let cases = [
            (arrival: Self.base, incoming: 10.0, expected: 10.0,
             latitude: 37.9693, longitude: 23.7112),
            (arrival: Self.base.addingTimeInterval(1_000), incoming: 30.0,
             expected: 20.0, latitude: 37.9838, longitude: 23.7275),
        ]

        for item in cases {
            await recorder.record(observation(
                arrival: item.arrival,
                receivedAt: item.arrival.addingTimeInterval(100), accuracy: 20), defaults: defaults)
            await recorder.record(observation(
                arrival: item.arrival,
                departure: item.arrival.addingTimeInterval(60),
                receivedAt: item.arrival.addingTimeInterval(120),
                latitude: 37.9693, longitude: 23.7112,
                accuracy: item.incoming), defaults: defaults)
        }

        let rows = try visits(in: container).sorted { $0.arrivalDate < $1.arrivalDate }
        #expect(rows.count == 2)
        for (row, item) in zip(rows, cases) {
            #expect(row.horizontalAccuracy == item.expected)
            #expect(row.latitude == item.latitude)
            #expect(row.longitude == item.longitude)
        }
    }

    @Test func differingClosedKept() async throws {
        let suiteName = "VisitRecorderTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = VisitRecorder(modelContainer: container)
        let firstDeparture = Self.base.addingTimeInterval(60)
        let firstReceipt = Self.base.addingTimeInterval(100)

        await recorder.record(observation(
            departure: firstDeparture, receivedAt: firstReceipt), defaults: defaults)
        await recorder.record(observation(
            departure: Self.base.addingTimeInterval(70),
            receivedAt: Self.base.addingTimeInterval(150)), defaults: defaults)

        let rows = try visits(in: container)
        #expect(rows.count == 1)
        #expect(rows.first?.departureDate == firstDeparture)
        #expect(rows.first?.receivedAt == firstReceipt)
    }

    @Test func closedThenOpen() async throws {
        let suiteName = "VisitRecorderTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = VisitRecorder(modelContainer: container)
        let departure = Self.base.addingTimeInterval(60)

        await recorder.record(observation(departure: departure), defaults: defaults)
        await recorder.record(observation(receivedAt: Self.base.addingTimeInterval(200)), defaults: defaults)

        let rows = try visits(in: container)
        #expect(rows.count == 1)
        #expect(rows.first?.departureDate == departure)
        #expect(rows.first?.receivedAt == Self.base.addingTimeInterval(100))
    }

    @Test func validationTable() async throws {
        let suiteName = "VisitRecorderTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = VisitRecorder(modelContainer: container)
        let invalid = [
            observation(arrival: .distantPast),
            observation(latitude: .nan),
            observation(latitude: 91),
            observation(longitude: -181),
            observation(accuracy: -1),
            observation(accuracy: 5_000),
            observation(
                arrival: Self.base.addingTimeInterval(301), receivedAt: Self.base),
            observation(departure: Self.base),
            observation(
                departure: Self.base.addingTimeInterval(401),
                receivedAt: Self.base.addingTimeInterval(100)),
        ]

        for input in invalid {
            await recorder.record(input, defaults: defaults)
            #expect(try visits(in: container).isEmpty)
        }
    }

    @Test func acceptanceFloor() async throws {
        let suiteName = "VisitRecorderTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = VisitRecorder(modelContainer: container)
        let oldArrival = Self.base.addingTimeInterval(-100_000)

        await recorder.record(observation(
            arrival: oldArrival, receivedAt: Self.base), defaults: defaults)
        #expect(try visits(in: container).count == 1)

        defaults.set(Self.base, forKey: VisitRecorder.acceptanceFloorKey)
        await recorder.record(observation(
            arrival: Self.base.addingTimeInterval(-1)), defaults: defaults)
        #expect(try visits(in: container).count == 1)
        await recorder.record(observation(arrival: Self.base), defaults: defaults)
        #expect(try visits(in: container).count == 2)
    }

    @Test func wipeFloorDoesNotAffectAnotherRecorder() async throws {
        let wipedSuite = "VisitRecorderWiped-\(UUID().uuidString)"
        let otherSuite = "VisitRecorderOther-\(UUID().uuidString)"
        let wipedDefaults = try #require(UserDefaults(suiteName: wipedSuite))
        let otherDefaults = try #require(UserDefaults(suiteName: otherSuite))
        defer {
            wipedDefaults.removePersistentDomain(forName: wipedSuite)
            otherDefaults.removePersistentDomain(forName: otherSuite)
        }
        wipedDefaults.set(Self.base, forKey: VisitRecorder.acceptanceFloorKey)
        otherDefaults.set(Self.base, forKey: VisitRecorder.acceptanceFloorKey)
        let wipedContainer = try TestSupport.makeInMemoryContainer()
        let otherContainer = try TestSupport.makeInMemoryContainer()
        #expect(DataWipe.execute(
            container: wipedContainer, defaults: wipedDefaults, clearDissolvedQueue: {}))

        await VisitRecorder(modelContainer: wipedContainer).record(
            observation(), defaults: wipedDefaults)
        await VisitRecorder(modelContainer: otherContainer).record(
            observation(), defaults: otherDefaults)

        #expect(try visits(in: wipedContainer).isEmpty)
        #expect(try visits(in: otherContainer).count == 1)
        #expect(otherDefaults.object(forKey: VisitRecorder.acceptanceFloorKey) as? Date == Self.base)
    }

    @Test func nearbyArrivalBitsStayDistinct() async throws {
        let suiteName = "VisitRecorderTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = VisitRecorder(modelContainer: container)

        await recorder.record(observation(arrival: Self.base), defaults: defaults)
        await recorder.record(observation(
            arrival: Self.base.addingTimeInterval(0.5)), defaults: defaults)

        #expect(try visits(in: container).count == 2)
    }

    @Test func distantCoordinatesStayDistinct() async throws {
        let suiteName = "VisitRecorderTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = VisitRecorder(modelContainer: container)

        await recorder.record(observation(), defaults: defaults)
        await recorder.record(observation(latitude: 38.0238), defaults: defaults)

        #expect(try visits(in: container).count == 2)
    }
}
