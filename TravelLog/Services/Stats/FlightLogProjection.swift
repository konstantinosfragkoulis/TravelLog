//
//  FlightLogProjection.swift
//  TravelLog
//
//  The flight rule every reader shares: the civil year a recorded flight
//  belongs to (the Flight Log's sections and filter, Siri's year summary,
//  new Wrapped).
//

import Foundation

nonisolated enum FlightLogProjection {
    typealias Flight = CollectionsAggregator.FlightRecord

    /// The flight's civil year: its saved arrival when valid, else its
    /// arrival, as a travel day in the arrival's zone (the device's for an
    /// unstamped stay, as the row's date reads). nil only for a date that
    /// is not a real instant.
    static func year(of flight: Flight) -> Int? {
        let arrival = savedTimes(flight)?.arrival ?? flight.date
        guard arrival.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let zone = StayTimeZone.resolve(flight.arrivalTimeZoneIdentifier)
        let label = TravelDays.label(for: arrival, zone: zone) ?? arrival
        return TravelDays.labelCalendar.component(.year, from: label)
    }

    private static func savedTimes(_ flight: Flight) -> FlightTimeOverrides.Times? {
        guard let times = flight.userTimes,
              [flight.date, flight.departureWindowStart]
                .compactMap({ $0 }).allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }),
              FlightTimeOverrides.fits(times, windowStart: flight.departureWindowStart,
                                       windowEnd: flight.date) else { return nil }
        return times
    }
}
