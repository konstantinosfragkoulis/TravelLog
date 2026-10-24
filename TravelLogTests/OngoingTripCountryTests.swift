//
//  OngoingTripCountryTests.swift
//  TravelLogTests
//
//  `Trip.countryCodeList` for an ongoing trip with no destination country:
//  it flags the trip's transit countries, while the stored `countryCodes`
//  stay destination-only.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct OngoingTripCountryTests {

    private func makeStay() -> Stay {
        Stay(startTime: .now, endTime: .now,
             centroidLatitude: 0, centroidLongitude: 0,
             h3IndexRes6: "hex", pingCount: 1, distanceFromHomeKm: 0, pingIDs: [])
    }

    /// Inserts a trip + its stays into a fresh in-memory context, linking each
    /// stay to the trip and assigning `orderInTrip` by array position.
    private func makeLinkedTrip(stays: [Stay]) throws -> Trip {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: .now)
        context.insert(trip)
        for (i, stay) in stays.enumerated() {
            context.insert(stay)
            stay.trip = trip
            stay.orderInTrip = i
        }
        return trip
    }

    @Test("an ongoing trip with no destination country flags its transit countries; stored codes stay destination-only")
    func ongoingAllTransitTripFlagsItsTransitCountry() throws {
        let first = makeStay(); first.category = .transit; first.isoCountryCode = "GR"
        let second = makeStay(); second.category = .transit; second.isoCountryCode = "GR"
        let trip = try makeLinkedTrip(stays: [first, second])
        trip.recomputeSummary()
        #expect(trip.countryCodes == "")
        #expect(trip.countryCodeList == ["GR"])
        #expect(trip.countryFlags == "🇬🇷")
        // Closed, the same stays flag nothing: completed trips show stored codes only.
        trip.isComplete = true
        #expect(trip.countryCodeList.isEmpty)
    }

    @Test("a destination country hides the transit countries of an ongoing trip")
    func ongoingTripDestinationCountryWins() throws {
        let layover = makeStay(); layover.category = .transit; layover.isoCountryCode = "DE"
        let city = makeStay(); city.category = .destination; city.isoCountryCode = "GB"
        let trip = try makeLinkedTrip(stays: [layover, city])
        trip.recomputeSummary()
        #expect(trip.countryCodeList == ["GB"])
    }
}
