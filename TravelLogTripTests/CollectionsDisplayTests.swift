//
//  CollectionsDisplayTests.swift
//  TravelLogTests
//
//  The Collections pages' derived figures (`CollectionsDisplay.swift`):
//  the flight totals' years, stations, routes, records and laps; the
//  Airports page's country cards and region; the Places page's kinds,
//  countries and new places. Pure values over fictional records.
//

import Testing
import Foundation
@testable import TravelLog

struct CollectionsDisplayTests {

    typealias Flight = CollectionsAggregator.FlightRecord

    private static let calendar = Calendar(identifier: .gregorian)

    /// Midday on 1 July of `year`, so no zone moves the flight's year.
    private static func midyear(_ year: Int, day: Int = 1) -> Date {
        calendar.date(from: DateComponents(timeZone: TimeZone(identifier: "UTC"), year: year, month: 7,
                                           day: day, hour: 12))!
    }

    private static let points: [String: (lat: Double, lon: Double)] = [
        "QQA": (44.3, 12.9), "QQB": (48.0, 2.0), "QQC": (40.0, -3.0), "QQD": (52.0, 13.0),
    ]

    private static let cities: [String: String] = ["QQA": "Velmora", "QQB": "Saltreach", "QQC": "Kelden"]

    private static func lookup(_ code: String) -> AirportRecord? {
        guard let point = points[code] else { return nil }
        return AirportRecord(code: code, lat: point.lat, lon: point.lon, name: "\(code) Field",
                             city: cities[code], iso: nil, svc: true)
    }

    private func flight(_ from: String?, _ to: String?, year: Int, day: Int = 1, km: Double,
                        fromPlace: String? = nil, stops: [String] = []) -> Flight {
        var record = Flight(
            id: UUID(), departureCode: from, arrivalCode: to,
            departurePlace: fromPlace ?? from.map { "\($0) town" }, arrivalPlace: to.map { "\($0) town" },
            departureISO: "AA", arrivalISO: "BB", date: Self.midyear(year, day: day), distanceKm: km,
            estimatedHours: CollectionsAggregator.estimatedHours(distanceKm: km),
            isInternational: true, timeZonesCrossed: 1, isOvernight: false, departureWindowStart: nil)
        if let from, let point = Self.points[from] {
            record.departureLatitude = point.lat
            record.departureLongitude = point.lon
        }
        if let to, let point = Self.points[to] {
            record.arrivalLatitude = point.lat
            record.arrivalLongitude = point.lon
        }
        if !stops.isEmpty {
            record.stops = stops.compactMap(Self.lookup).map(Flight.Stop.init)
        }
        return record
    }

    // MARK: Flight totals

    @Test("years run oldest to newest from the first flight to the current year, gaps as zero")
    func yearsFillTheRange() {
        let flights = [flight("QQA", "QQB", year: 2021, km: 900),
                       flight("QQB", "QQA", year: 2021, day: 9, km: 900),
                       flight("QQA", "QQC", year: 2023, km: 1_400)]
        let summary = FlightTotalsSummary(flights, currentYear: 2026, airport: Self.lookup)
        #expect(summary.years.map(\.year) == Array(2021...2026))
        #expect(summary.years.map(\.flights) == [2, 0, 1, 0, 0, 0])
        #expect(summary.busiestYear == .init(year: 2021, flights: 2))

        // A flight dated past the current year still ends the range.
        let ahead = FlightTotalsSummary([flight("QQA", "QQB", year: 2027, km: 900)], currentYear: 2026,
                                        airport: Self.lookup)
        #expect(ahead.years.map(\.year) == [2027])
        #expect(FlightTotalsSummary([], currentYear: 2026).years.isEmpty)
    }

    @Test("a station counts each journey through it once, busiest first, and keeps its first year")
    func stationsAndBusiestAirports() {
        let flights = [flight("QQA", "QQB", year: 2024, km: 900, stops: ["QQC"]),
                       flight("QQB", "QQA", year: 2019, km: 900),
                       flight(nil, "QQA", year: 2022, km: 300, fromPlace: "Westhaven")]
        let summary = FlightTotalsSummary(flights, currentYear: 2026, airport: Self.lookup)
        #expect(summary.stations.map(\.id) == ["QQA", "QQB", "QQC", "Westhaven"])
        #expect(summary.stations.map(\.flights) == [3, 2, 1, 1])
        #expect(summary.stations.first?.firstYear == 2019)
        #expect(summary.stations.first?.city == "Velmora")
        // A place end is a station on the map, never an airport.
        #expect(summary.airports.map(\.id) == ["QQA", "QQB", "QQC"])
        let place = summary.stations.first { $0.id == "Westhaven" }
        #expect(place?.code == nil && place?.latitude == nil)
    }

    @Test("routes join stations either way through the stops, least flown first")
    func routesCountBothWays() {
        let flights = [flight("QQA", "QQB", year: 2024, km: 900),
                       flight("QQB", "QQA", year: 2024, day: 5, km: 900),
                       flight("QQA", "QQD", year: 2025, km: 1_100, stops: ["QQC"])]
        let summary = FlightTotalsSummary(flights, currentYear: 2026, airport: Self.lookup)
        #expect(summary.routes.map { "\($0.from)-\($0.to)×\($0.flights)" }
                == ["QQA-QQC×1", "QQC-QQD×1", "QQA-QQB×2"])
        #expect(summary.mostFlown?.first.label == "QQA")
        #expect(summary.mostFlown?.second.label == "QQB")
        #expect(summary.mostFlown?.flights == 2)
        #expect(summary.mostFlown?.first.city == "Velmora")
    }

    @Test("the records are the longest and shortest hops; one hop has no shortest, no repeat no most flown")
    func records() throws {
        let one = FlightTotalsSummary([flight("QQA", "QQB", year: 2024, km: 900)], currentYear: 2026,
                                      airport: Self.lookup)
        #expect(one.longest?.distanceKm == 900)
        #expect(one.shortest == nil)
        #expect(one.mostFlown == nil)

        let flights = [flight("QQA", "QQB", year: 2024, km: 900),
                       flight("QQB", "QQC", year: 2024, day: 5, km: 1_200),
                       flight("QQC", "QQA", year: 2025, km: 0)]
        let summary = FlightTotalsSummary(flights, currentYear: 2026, airport: Self.lookup)
        let longest = try #require(summary.longest)
        #expect(longest.from.label == "QQB" && longest.to.label == "QQC")
        #expect(longest.from.city == "Saltreach")
        #expect(longest.estimatedHours == CollectionsAggregator.estimatedHours(distanceKm: 1_200))
        // A hop of no known distance is no record.
        #expect(summary.shortest?.distanceKm == 900)
    }

    @Test("one globe per lap of the Earth, the last one as far as it got")
    func laps() {
        let earth = FlightTotalsSummary.earthCircumferenceKm
        #expect(FlightTotalsSummary.laps(km: 0).isEmpty)
        #expect(FlightTotalsSummary.laps(km: -5).isEmpty)
        #expect(FlightTotalsSummary.laps(km: .nan).isEmpty)
        let short = FlightTotalsSummary.laps(km: earth * 0.004)
        #expect(short.count == 1 && abs(short[0] - 0.004) < 1e-9)
        #expect(FlightTotalsSummary.laps(km: earth * 3) == [1, 1, 1])
        // A hair past whole laps adds no empty globe.
        #expect(FlightTotalsSummary.laps(km: earth * 3.004) == [1, 1, 1])
        let partial = FlightTotalsSummary.laps(km: earth * 10.25)
        #expect(partial.count == 11)
        #expect(partial.prefix(10).allSatisfy { $0 == 1 })
        #expect(abs(partial[10] - 0.25) < 1e-9)
    }

    // MARK: Airports

    private func airport(_ code: String, _ iso: String?, visits: Int, flown: Bool = true)
        -> CollectionsAggregator.AirportEntry {
        CollectionsAggregator.AirportEntry(
            code: code, name: nil, city: nil, isoCountryCode: iso, hasScheduledService: true,
            stayCount: visits, firstVisit: Self.midyear(2020), lastVisit: Self.midyear(2024),
            flownThrough: flown)
    }

    @Test("country cards: most visits first, their airports most visited first, no country last")
    func countryCards() {
        let cards = AirportsDisplay.countryCards([
            airport("QQB", "fr", visits: 3), airport("QQA", "FR", visits: 3, flown: false),
            airport("QQC", "JP", visits: 9), airport("QQD", nil, visits: 40),
            airport("QQE", "DE", visits: 6), airport("QQF", "FR", visits: 5),
        ])
        #expect(cards.map(\.isoCountryCode) == ["FR", "JP", "DE", nil])
        #expect(cards[0].airports.map(\.code) == ["QQF", "QQA", "QQB"])
        #expect(cards[0].visits == 11)
        #expect(cards[0].flownCount == 2)
        #expect(AirportsDisplay.countryCards([]).isEmpty)
    }

    @Test("the region is the busiest continent, and none when the airports share one")
    func region() {
        #expect(AirportsDisplay.region([airport("QQA", "FR", visits: 9), airport("QQB", "DE", visits: 2)]) == nil)
        #expect(AirportsDisplay.region([]) == nil)
        let mixed = [airport("QQA", "FR", visits: 9), airport("QQB", "DE", visits: 2),
                     airport("QQC", "JP", visits: 10), airport("QQD", nil, visits: 50)]
        #expect(AirportsDisplay.region(mixed) == "150")
        #expect(AirportsDisplay.continents(mixed) == ["150", "142"])
        let americas = [airport("QQE", "US", visits: 4), airport("QQF", "BR", visits: 4)]
        #expect(AirportsDisplay.continents(americas) == ["NA", "SA"])
        #expect(AirportsDisplay.regionCode(forContinent: "NA") == "003")
        #expect(AirportsDisplay.regionCode(forContinent: "150") == "150")
    }

    // MARK: Places

    private func place(_ id: String, _ kind: CollectionsAggregator.PlaceKind, iso: String?,
                       country: String? = nil, first: Date) -> CollectionsAggregator.PlaceEntry {
        CollectionsAggregator.PlaceEntry(
            id: id, name: id, isoCountryCode: iso, country: country, kind: kind, tripCount: 1,
            stayCount: 1, dayCount: 2, firstVisit: first, lastVisit: first, localities: [])
    }

    @Test("kinds in chip order, only those present; countries by code, else by name")
    func kindsAndCountries() {
        let places = [place("Velmora", .island, iso: "AA", first: Self.midyear(2020)),
                      place("Saltreach", .metro, iso: "aa", first: Self.midyear(2020)),
                      place("Kelden", .area, iso: nil, country: "Eastmere", first: Self.midyear(2020)),
                      place("Westhaven", .metro, iso: nil, first: Self.midyear(2020))]
        #expect(PlacesDisplay.kindCounts(places) == [.init(kind: .metro, count: 2), .init(kind: .island, count: 1),
                                                     .init(kind: .area, count: 1)])
        #expect(PlacesDisplay.countryCount(places) == 2)
        #expect(PlacesDisplay.kindCounts([]).isEmpty)
    }

    @Test("new this year: first visited in the current calendar year, newest first")
    func newThisYear() {
        var calendar = Self.calendar
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Self.midyear(2026, day: 20)
        let places = [place("Velmora", .metro, iso: "AA", first: Self.midyear(2026, day: 2)),
                      place("Saltreach", .locality, iso: "AA", first: Self.midyear(2025)),
                      place("Kelden", .area, iso: "AA", first: Self.midyear(2026, day: 9))]
        #expect(PlacesDisplay.newThisYear(places, now: now, calendar: calendar).map(\.id) == ["Kelden", "Velmora"])
        #expect(PlacesDisplay.newThisYear([], now: now, calendar: calendar).isEmpty)
    }
}
