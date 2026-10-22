//
//  FlightTimeOverridesTests.swift
//  TravelLogTests
//
//  The times a user sets for a flight in the Flight Log
//  (`FlightTimeOverrides`): the device-local ledger, its bounds, how the
//  aggregate applies it to the log and its totals, the detail sheet's
//  context, and the backup merge. Fictional places on round coordinates
//  with injected fixture airports; fictional dates.
//

import Testing
import Foundation
import CoreLocation
import SwiftData
@testable import TravelLog

@MainActor
struct FlightTimeOverridesTests {

    private typealias Times = FlightTimeOverrides.Times

    /// Fictional fixture airports on round coordinates, about 1,100 km apart.
    private static let west = AirportRecord(
        code: "QQA", lat: 10, lon: 0, name: "Westhaven Field", city: "Westhaven", iso: "AA", svc: true)
    private static let east = AirportRecord(
        code: "QQB", lat: 10, lon: 10, name: "Eastmere International", city: "Eastmere", iso: "BB", svc: true)

    private static func resolver(_ coordinate: CLLocationCoordinate2D) -> AirportRecord? {
        [west, east].first {
            CollectionsAggregator.haversineKm(lat1: coordinate.latitude, lon1: coordinate.longitude,
                                              lat2: $0.lat, lon2: $0.lon) <= 3
        }
    }

    /// Hours after a fictional midnight UTC.
    private static func at(_ hours: Double) -> Date {
        let base: TimeInterval = 1_900_000_000
        return Date(timeIntervalSince1970: base - base.truncatingRemainder(dividingBy: 86_400) + hours * 3600)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "FlightTimeOverridesTests-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    private func makeStay(
        lat: Double, lon: Double, start: Date, end: Date,
        category: StayCategory = .transit, transit: TransitMode? = nil, locality: String? = nil
    ) -> Stay {
        let stay = Stay(
            startTime: start, endTime: end,
            centroidLatitude: lat, centroidLongitude: lon,
            h3IndexRes6: "", pingCount: 1, distanceFromHomeKm: 500, pingIDs: []
        )
        stay.category = category
        stay.isAirport = true
        stay.transitFromPreviousRaw = transit?.rawValue
        stay.locality = locality
        return stay
    }

    /// A west-to-east flight: last fix at the origin at hour 5, first at the
    /// destination at hour 8, and the stays it joins inserted and saved so
    /// their identifiers are permanent.
    private func flightLeg(
        in context: ModelContext
    ) throws -> (departure: Stay, arrival: Stay, trip: Trip) {
        let trip = Trip(startDate: Self.at(0))
        context.insert(trip)
        let departure = makeStay(lat: 10.001, lon: 0.001, start: Self.at(0), end: Self.at(5),
                                 locality: "Westhaven")
        let arrival = makeStay(lat: 10.001, lon: 10.001, start: Self.at(8), end: Self.at(30),
                               transit: .flight, locality: "Eastmere")
        context.insert(departure)
        context.insert(arrival)
        arrival.trip = trip
        try context.save()
        return (departure, arrival, trip)
    }

    private func aggregate(
        _ stays: [Stay], flightTimes: [UUID: Times] = [:]
    ) -> CollectionsAggregator.Collections {
        CollectionsAggregator.aggregate(
            rows: stays.map { CollectionsAggregator.StayRow($0) }, predecessorOnly: [],
            nearestAirport: Self.resolver, dismissedCandidates: [],
            flightTimes: flightTimes, checkCancellation: {})
    }

    // MARK: Ledger

    @Test("setting times replaces the earlier entry, and clearing keeps a tombstone")
    func setReplacesAndClearRemoves() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let other = UUID()
        FlightTimeOverrides.set(Times(departure: Self.at(1), arrival: Self.at(3)), for: id, defaults: defaults)
        FlightTimeOverrides.set(Times(departure: Self.at(2), arrival: Self.at(4)), for: other, defaults: defaults)
        FlightTimeOverrides.set(Times(departure: Self.at(5), arrival: Self.at(6)), for: id, defaults: defaults)

        #expect(defaults.stringArray(forKey: FlightTimeOverrides.defaultsKey)?.count == 2)
        #expect(FlightTimeOverrides.times(for: id, defaults: defaults) == Times(departure: Self.at(5), arrival: Self.at(6)))

        FlightTimeOverrides.clear(id, defaults: defaults)
        #expect(FlightTimeOverrides.times(for: id, defaults: defaults) == nil)
        #expect(FlightTimeOverrides.times(for: other, defaults: defaults) != nil)
        FlightTimeOverrides.clear(other, defaults: defaults)
        #expect(FlightTimeOverrides.all(defaults: defaults).isEmpty)
        #expect(Set(defaults.stringArray(forKey: FlightTimeOverrides.defaultsKey) ?? [])
            == Set([id.uuidString, other.uuidString]))
    }

    @Test("when the list names a flight twice the later entry wins, and unreadable entries are skipped")
    func laterEntryWinsAndJunkIsSkipped() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let earlier = FlightTimeOverrides.entry(id: id, times: Times(departure: Self.at(1), arrival: Self.at(3)))
        let later = FlightTimeOverrides.entry(id: id, times: Times(departure: Self.at(2), arrival: Self.at(4)))
        let reversed = FlightTimeOverrides.entry(id: UUID(), times: Times(departure: Self.at(4), arrival: Self.at(2)))
        let tooLong = FlightTimeOverrides.entry(id: UUID(), times: Times(departure: Self.at(0), arrival: Self.at(60)))
        defaults.set([earlier, "not an entry", reversed, tooLong, later], forKey: FlightTimeOverrides.defaultsKey)

        let all = FlightTimeOverrides.all(defaults: defaults)
        #expect(all.count == 1)
        #expect(all[id] == Times(departure: Self.at(2), arrival: Self.at(4)))
    }

    @Test("times fit only inside the observed window widened by the slack, with a flight's duration")
    func fitsTheWindow() {
        let start = Self.at(5), end = Self.at(8)
        #expect(FlightTimeOverrides.fits(Times(departure: Self.at(5.5), arrival: Self.at(7.5)), windowStart: start, windowEnd: end))
        #expect(FlightTimeOverrides.fits(Times(departure: Self.at(2.5), arrival: Self.at(10.5)), windowStart: start, windowEnd: end))
        #expect(!FlightTimeOverrides.fits(Times(departure: Self.at(1), arrival: Self.at(7)), windowStart: start, windowEnd: end))
        #expect(!FlightTimeOverrides.fits(Times(departure: Self.at(6), arrival: Self.at(12)), windowStart: start, windowEnd: end))
        // Shorter than the minimum.
        #expect(!FlightTimeOverrides.fits(Times(departure: Self.at(6), arrival: Self.at(6.1)), windowStart: start, windowEnd: end))
        // No origin fix: the window reaches back the longest duration.
        #expect(FlightTimeOverrides.fits(Times(departure: Self.at(-30), arrival: Self.at(8)), windowStart: nil, windowEnd: end))
    }

    @Test("the editor starts landing at the first fix, the estimate earlier, inside the window")
    func suggestedTimes() {
        let wide = FlightTimeOverrides.suggested(windowStart: Self.at(0), windowEnd: Self.at(72), estimatedHours: 2)
        #expect(wide == Times(departure: Self.at(70), arrival: Self.at(72)))
        let narrow = FlightTimeOverrides.suggested(windowStart: Self.at(71), windowEnd: Self.at(72), estimatedHours: 2)
        #expect(narrow == Times(departure: Self.at(71), arrival: Self.at(72)))
        #expect(FlightTimeOverrides.fits(narrow, windowStart: Self.at(71), windowEnd: Self.at(72)))
    }

    // MARK: Aggregate

    @Test("the user's times replace the estimate in the flight's hours and the totals")
    func userTimesReplaceTheEstimate() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let leg = try flightLeg(in: context)

        let derived = try #require(aggregate([leg.departure, leg.arrival]).flights.first)
        #expect(derived.userTimes == nil)
        #expect(derived.flightHours == derived.estimatedHours)

        let times = Times(departure: Self.at(5.5), arrival: Self.at(7.5))
        let result = aggregate([leg.departure, leg.arrival], flightTimes: [leg.arrival.id: times])
        let flight = try #require(result.flights.first)
        #expect(flight.userTimes == times)
        #expect(flight.flightHours == 2)
        #expect(flight.estimatedHours == derived.estimatedHours)
        #expect(result.flightStats.totalEstimatedHours == 2)
        #expect(result.flightStats.totalKm == derived.distanceKm)
    }

    @Test("times that no longer fit the leg's window are not applied")
    func staleTimesAreNotApplied() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let leg = try flightLeg(in: context)
        let elsewhere = Times(departure: Self.at(40), arrival: Self.at(42))

        let flight = try #require(aggregate([leg.departure, leg.arrival],
                                            flightTimes: [leg.arrival.id: elsewhere]).flights.first)
        #expect(flight.userTimes == nil)
        #expect(flight.flightHours == flight.estimatedHours)
    }

    @Test("the overnight mark follows the user's times at the departure longitude")
    func overnightFollowsUserTimes() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let leg = try flightLeg(in: context)
        // The derived window (05:00 to 08:00 solar at 0°) holds no 02:00.
        let derived = try #require(aggregate([leg.departure, leg.arrival]).flights.first)
        #expect(!derived.flewOvernight)
        #expect(aggregate([leg.departure, leg.arrival]).flightStats.overnightCount == 0)

        // A 02:00 departure, inside the window's slack, holds the red-eye hour.
        let redEye = Times(departure: Self.at(2.0), arrival: Self.at(4.5))
        let result = aggregate([leg.departure, leg.arrival], flightTimes: [leg.arrival.id: redEye])
        let flight = try #require(result.flights.first)
        #expect(flight.flewOvernight)
        #expect(result.flightStats.overnightCount == 1)
    }

    @Test("the detail context names the airports, the stays' spans, the points and the trip")
    func detailContext() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let leg = try flightLeg(in: context)

        let flight = try #require(aggregate([leg.departure, leg.arrival]).flights.first)
        #expect(flight.departureAirportName == "Westhaven Field")
        #expect(flight.arrivalAirportName == "Eastmere International")
        #expect(flight.departureLatitude == Self.west.lat && flight.departureLongitude == Self.west.lon)
        #expect(flight.arrivalLatitude == Self.east.lat && flight.arrivalLongitude == Self.east.lon)
        #expect(flight.departureStayStart == Self.at(0))
        #expect(flight.arrivalStayEnd == Self.at(30))
        #expect(flight.arrivalTripID == leg.trip.id)
        #expect(flight.departureTripID == nil)
        #expect(flight.departureIsHome == false)
        #expect(flight.arrivalIsHome == false)
    }

    @Test("a record from a snapshot written before the context decodes with none")
    func olderSnapshotDecodes() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let leg = try flightLeg(in: context)
        let flight = try #require(aggregate([leg.departure, leg.arrival]).flights.first)

        var object = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(flight)) as? [String: Any])
        for key in ["departureAirportName", "arrivalAirportName", "departureLatitude", "departureLongitude",
                    "arrivalLatitude", "arrivalLongitude", "departureStayStart", "arrivalStayEnd",
                    "departureIsHome", "arrivalIsHome", "departureTripID", "arrivalTripID",
                    "userDeparture", "userArrival"] {
            object[key] = nil
        }
        let decoded = try JSONDecoder().decode(
            CollectionsAggregator.FlightRecord.self,
            from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.id == flight.id)
        #expect(decoded.departureAirportName == nil)
        #expect(decoded.userTimes == nil)
        #expect(decoded.flightHours == flight.estimatedHours)
    }

    // MARK: Backup

    @Test("a restored backup adds times this device lacks and never replaces its own")
    func backupMergeKeepsThisDevicesTimes() throws {
        let (defaults, suite) = try makeDefaults()
        let (ubiquitous, ubiquitousSuite) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suite)
            ubiquitous.removePersistentDomain(forName: ubiquitousSuite)
        }
        let kept = UUID(), added = UUID()
        let mine = Times(departure: Self.at(1), arrival: Self.at(3))
        FlightTimeOverrides.set(mine, for: kept, defaults: defaults)

        var preferences = BackupPreferences()
        preferences.flightTimeOverrides = [
            FlightTimeOverrides.entry(id: kept, times: Times(departure: Self.at(10), arrival: Self.at(12))),
            FlightTimeOverrides.entry(id: added, times: Times(departure: Self.at(20), arrival: Self.at(22))),
        ]
        BackupPreferences.restore(preferences, defaults: defaults, ubiquitous: ubiquitous)

        let all = FlightTimeOverrides.all(defaults: defaults)
        #expect(all[kept] == mine)
        #expect(all[added] == Times(departure: Self.at(20), arrival: Self.at(22)))
        #expect(BackupPreferences.current(defaults: defaults, ubiquitous: ubiquitous).flightTimeOverrides?.count == 3)
    }
}
