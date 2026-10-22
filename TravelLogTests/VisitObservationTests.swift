//
//  VisitObservationTests.swift
//  TravelLogTests
//
//  Pins for the production CLVisit value seam. The adapter records the raw
//  scalar payload while normalizing only Core Location's documented open-
//  interval sentinels.
//

import CoreLocation
import Foundation
import Testing
@testable import TravelLog

@Suite("Visit observation adapter")
struct VisitObservationTests {

    private struct StubVisit: VisitEventSource {
        let coordinate: CLLocationCoordinate2D
        let horizontalAccuracy: CLLocationAccuracy
        let arrivalDate: Date
        let departureDate: Date
    }

    @Test func adapterNormalizesDistantPastAndDistantFuture() {
        let receivedAt = Date(timeIntervalSinceReferenceDate: 900)
        let observation = VisitObservation(
            source: StubVisit(
                coordinate: CLLocationCoordinate2D(
                    latitude: 37.9838, longitude: 23.7275),
                horizontalAccuracy: 42.5,
                arrivalDate: .distantPast,
                departureDate: .distantFuture),
            receivedAt: receivedAt)

        #expect(observation.latitude == 37.9838)
        #expect(observation.longitude == 23.7275)
        #expect(observation.horizontalAccuracy == 42.5)
        #expect(observation.receivedAt == receivedAt)
        #expect(observation.arrivalDate == nil)
        #expect(observation.departureDate == nil)
        #expect(observation.arrivalWasDistantPast)
        #expect(observation.departureWasDistantFuture)
    }

    @Test func adapterPreservesFiniteDates() {
        let arrival = Date(timeIntervalSinceReferenceDate: 100)
        let departure = Date(timeIntervalSinceReferenceDate: 500)
        let observation = VisitObservation(
            source: StubVisit(
                coordinate: CLLocationCoordinate2D(
                    latitude: 39.6628, longitude: 20.8612),
                horizontalAccuracy: 18,
                arrivalDate: arrival,
                departureDate: departure),
            receivedAt: Date(timeIntervalSinceReferenceDate: 700))

        #expect(observation.arrivalDate == arrival)
        #expect(observation.departureDate == departure)
        #expect(!observation.arrivalWasDistantPast)
        #expect(!observation.departureWasDistantFuture)
    }

    @Test func adapterCopiesInvalidValuesWithoutAdjudicatingThem() {
        let observation = VisitObservation(
            source: StubVisit(
                coordinate: CLLocationCoordinate2D(
                    latitude: .nan, longitude: .infinity),
                horizontalAccuracy: -7.5,
                arrivalDate: Date(timeIntervalSinceReferenceDate: 100),
                departureDate: Date(timeIntervalSinceReferenceDate: 200)),
            receivedAt: Date(timeIntervalSinceReferenceDate: 300))

        #expect(observation.latitude.isNaN)
        #expect(observation.longitude == .infinity)
        #expect(observation.horizontalAccuracy == -7.5)
    }
}
