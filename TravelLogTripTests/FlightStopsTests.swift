//
//  FlightStopsTests.swift
//  TravelLogTests
//
//  The connections a user adds to a flight in the Flight Log
//  (`FlightStops`): the device-local ledger, the suggestions on the way and
//  the airport search, how the aggregate counts the legs and the stop
//  airports, the "When did you fly?" answers, older snapshots and the
//  backup merge. Fictional places on round coordinates with injected
//  fixture airports; real airports come from the bundled dataset at run
//  time. Fictional dates.
//

import Testing
import Foundation
import CoreLocation
import SwiftData
@testable import TravelLog

@MainActor
struct FlightStopsTests {

    private typealias Times = FlightTimeOverrides.Times

    /// Fictional fixture airports on round coordinates along one parallel:
    /// the ends 10° apart, a stop off centre on the way, one off the route.
    private static let west = AirportRecord(
        code: "QQA", lat: 10, lon: 0, name: "Westhaven Field", city: "Westhaven", iso: "AA", svc: true)
    private static let east = AirportRecord(
        code: "QQB", lat: 10, lon: 10, name: "Eastmere International", city: "Eastmere", iso: "BB", svc: true)
    private static let middle = AirportRecord(
        code: "QQC", lat: 10, lon: 3, name: "Midwater Airport", city: "Midwater", iso: "CC", svc: true)
    private static let nearEast = AirportRecord(
        code: "QQD", lat: 10, lon: 7, name: "Lowmarsh Airport", city: "Lowmarsh", iso: "BB", svc: true)
    private static let farNorth = AirportRecord(
        code: "QQE", lat: 30, lon: 5, name: "Northreach Airport", city: "Northreach", iso: "DD", svc: true)
    private static let unscheduled = AirportRecord(
        code: "QQF", lat: 10, lon: 5, name: "Greyfield Base", city: "Greyfield", iso: "CC", svc: false)
    private static let fixtures = [west, east, middle, nearEast, farNorth, unscheduled]

    private static func resolver(_ coordinate: CLLocationCoordinate2D) -> AirportRecord? {
        fixtures.first {
            CollectionsAggregator.haversineKm(lat1: coordinate.latitude, lon1: coordinate.longitude,
                                              lat2: $0.lat, lon2: $0.lon) <= 3
        }
    }

    private static func byCode(_ code: String) -> AirportRecord? {
        fixtures.first { $0.code == code }
    }

    private static func km(_ a: AirportRecord, _ b: AirportRecord) -> Double {
        CollectionsAggregator.haversineKm(lat1: a.lat, lon1: a.lon, lat2: b.lat, lon2: b.lon)
    }

    /// Hours after a fictional midnight UTC.
    private static func at(_ hours: Double) -> Date {
        let base: TimeInterval = 1_900_000_000
        return Date(timeIntervalSince1970: base - base.truncatingRemainder(dividingBy: 86_400) + hours * 3600)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "FlightStopsTests-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    private func makeStay(
        lat: Double, lon: Double, start: Date, end: Date,
        transit: TransitMode? = nil, locality: String? = nil
    ) -> Stay {
        let stay = Stay(
            startTime: start, endTime: end,
            centroidLatitude: lat, centroidLongitude: lon,
            h3IndexRes6: "", pingCount: 1, distanceFromHomeKm: 500, pingIDs: []
        )
        stay.category = .transit
        stay.isAirport = true
        stay.transitFromPreviousRaw = transit?.rawValue
        stay.locality = locality
        return stay
    }

    /// A west-to-east flight: last fix at the origin at hour 5, first at
    /// the destination at `arrivalHour`.
    private func flightLeg(
        in context: ModelContext, arrivalHour: Double = 20
    ) throws -> (departure: Stay, arrival: Stay) {
        let departure = makeStay(lat: 10.001, lon: 0.001, start: Self.at(0), end: Self.at(5),
                                 locality: "Westhaven")
        let arrival = makeStay(lat: 10.001, lon: 10.001, start: Self.at(arrivalHour),
                               end: Self.at(arrivalHour + 30), transit: .flight, locality: "Eastmere")
        context.insert(departure)
        context.insert(arrival)
        try context.save()
        return (departure, arrival)
    }

    private func aggregate(
        _ stays: [Stay], flightStops: [UUID: [String]] = [:], flightTimes: [UUID: Times] = [:]
    ) -> CollectionsAggregator.Collections {
        CollectionsAggregator.aggregate(
            rows: stays.map { CollectionsAggregator.StayRow($0) }, predecessorOnly: [],
            nearestAirport: Self.resolver, dismissedCandidates: [],
            flightTimes: flightTimes, flightStops: flightStops, airportByCode: Self.byCode,
            checkCancellation: {})
    }

    // MARK: Ledger

    @Test("setting stops replaces the flight's entry, a nonstop is kept as the uuid alone, and clearing removes it")
    func setNonstopAndClear() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID(), other = UUID()
        FlightStops.set(["FRA"], for: id, defaults: defaults)
        FlightStops.set(["IST", "DXB"], for: other, defaults: defaults)
        FlightStops.set(["MUC", "ZRH"], for: id, defaults: defaults)
        #expect(defaults.stringArray(forKey: FlightStops.defaultsKey)?.count == 2)
        #expect(FlightStops.stops(for: id, defaults: defaults) == ["MUC", "ZRH"])

        FlightStops.set([], for: id, defaults: defaults)
        #expect(defaults.stringArray(forKey: FlightStops.defaultsKey)?.last == id.uuidString)
        #expect(FlightStops.stops(for: id, defaults: defaults) == [])
        #expect(FlightStops.stops(for: other, defaults: defaults) == ["IST", "DXB"])

        FlightStops.clear(id, defaults: defaults)
        #expect(FlightStops.stops(for: id, defaults: defaults) == nil)
        FlightStops.clear(other, defaults: defaults)
        #expect(defaults.object(forKey: FlightStops.defaultsKey) == nil)
    }

    @Test("when the list names a flight twice the later entry wins, and unreadable entries are skipped")
    func laterEntryWinsAndJunkIsSkipped() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID(), reset = UUID()
        defaults.set([
            FlightStops.entry(id: id, codes: ["FRA"]),
            "not an entry",
            "\(UUID().uuidString) fra",
            "\(UUID().uuidString) FRA MUC ZRH",
            "\(UUID().uuidString) FRANKFURT",
            FlightStops.entry(id: reset, codes: ["IST"]),
            FlightStops.entry(id: id, codes: ["MUC", "VIE"]),
            reset.uuidString,
        ], forKey: FlightStops.defaultsKey)

        let all = FlightStops.all(defaults: defaults)
        #expect(all.count == 2)
        #expect(all[id] == ["MUC", "VIE"])
        #expect(all[reset] == [])
    }

    // MARK: Suggestions

    @Test("suggestions keep airports on the way, visited first, then by detour, never an end's own")
    func suggestionsOnTheWay() {
        let suggested = FlightStops.suggestions(
            fromLatitude: Self.west.lat, fromLongitude: Self.west.lon,
            toLatitude: Self.east.lat, toLongitude: Self.east.lon,
            excluding: ["QQA", "QQB"], visited: ["QQD"],
            hubs: ["QQC", "QQE", "QQF", "QQA", "QQD"], resolve: Self.byCode)
        // QQD was visited, so it leads; QQC is the only other hub on the
        // way. QQE is far off the route, QQF has no scheduled service.
        #expect(suggested.map(\.code) == ["QQD", "QQC"])

        // Judged on the remaining leg once QQD is a stop: QQC lies behind it.
        let second = FlightStops.suggestions(
            fromLatitude: Self.nearEast.lat, fromLongitude: Self.nearEast.lon,
            toLatitude: Self.east.lat, toLongitude: Self.east.lon,
            excluding: ["QQA", "QQB", "QQD"], visited: [],
            hubs: ["QQC"], resolve: Self.byCode)
        #expect(second.isEmpty)

        // An airport beside an end is that end's own.
        let beside = AirportRecord(code: "QQG", lat: 10.2, lon: 9.9, name: nil, city: nil, iso: nil, svc: true)
        let nearEnd = FlightStops.suggestions(
            fromLatitude: Self.west.lat, fromLongitude: Self.west.lon,
            toLatitude: Self.east.lat, toLongitude: Self.east.lon,
            excluding: [], visited: [], hubs: ["QQG"],
            resolve: { $0 == "QQG" ? beside : nil })
        #expect(nearEnd.isEmpty)
    }

    @Test("suggestions rank hubs by detour and stop at the limit")
    func suggestionsRankAndLimit() {
        let hubs = (1...9).map { index in
            AirportRecord(code: "QR\(index)", lat: 10 + Double(index) * 0.2, lon: 5,
                          name: nil, city: nil, iso: nil, svc: true)
        }
        let suggested = FlightStops.suggestions(
            fromLatitude: 10, fromLongitude: 0, toLatitude: 10, toLongitude: 10,
            excluding: [], visited: [], hubs: hubs.reversed().map(\.code),
            resolve: { code in hubs.first { $0.code == code } })
        #expect(suggested.count == FlightStops.suggestionLimit)
        #expect(suggested.map(\.code) == ["QR1", "QR2", "QR3", "QR4", "QR5", "QR6"])
    }

    @Test("with the bundled airports, a long flight suggests hubs on its way and none far off it")
    func realHubSuggestions() throws {
        let detector = AirportDetector.shared
        let from = try #require(detector.airport(code: "ATH"))
        let to = try #require(detector.airport(code: "LAX"))
        let codes = FlightStops.suggestions(
            fromLatitude: from.lat, fromLongitude: from.lon,
            toLatitude: to.lat, toLongitude: to.lon,
            excluding: ["ATH", "LAX"], visited: [], resolve: { detector.airport(code: $0) },
            limit: 40).map(\.code)
        #expect(codes.contains("FRA"))
        #expect(!codes.contains("SYD"))
        #expect(!codes.contains("DXB"))
        #expect(!codes.contains("ATH") && !codes.contains("LAX"))
        // Every hub the list names is in the dataset.
        #expect(FlightStops.hubCodes.allSatisfy { detector.airport(code: $0) != nil })
    }

    @Test("the airport search finds the exact code first, then cities and names, ignoring case and accents")
    func airportSearch() throws {
        let index = FlightStops.SearchIndex(AirportDetector.shared.allAirports)
        #expect(FlightStops.search("fra", in: index).first?.code == "FRA")
        #expect(FlightStops.search("Frankfurt", in: index).map(\.code).contains("FRA"))
        #expect(FlightStops.search("malaga", in: index).map(\.code).contains("AGP"))
        #expect(FlightStops.search("  ", in: index).isEmpty)
        #expect(FlightStops.search("London", in: index).count <= FlightStops.searchLimit)

        // Only scheduled airports with an IATA code can be stops.
        let fixtures = FlightStops.SearchIndex([Self.middle, Self.unscheduled])
        #expect(FlightStops.search("QQ", in: fixtures).map(\.code) == ["QQC"])
    }

    // MARK: Legs

    @Test("connections refine one recorded journey without multiplying the flight count")
    func legStats() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let leg = try flightLeg(in: context)

        let nonstop = aggregate([leg.departure, leg.arrival])
        #expect(nonstop.flightStats.totalFlights == 1)
        let direct = try #require(nonstop.flights.first)
        #expect(direct.legs.count == 1)
        #expect(direct.flownKm == direct.distanceKm)
        #expect(direct.legsEstimatedHours == direct.estimatedHours)

        let result = aggregate([leg.departure, leg.arrival], flightStops: [leg.arrival.id: ["QQC"]])
        let flight = try #require(result.flights.first)
        let first = Self.km(Self.west, Self.middle), second = Self.km(Self.middle, Self.east)
        #expect(flight.stops?.map(\.code) == ["QQC"])
        #expect(flight.routeLabel == "QQA → QQC → QQB")
        #expect(flight.placeRouteLabel == "Westhaven → Midwater → Eastmere")
        #expect(flight.legs.map(\.routeLabel) == ["QQA → QQC", "QQC → QQB"])
        // The journey's own distance stays end to end.
        #expect(flight.distanceKm == direct.distanceKm)

        let stats = result.flightStats
        let hours = CollectionsAggregator.estimatedHours(distanceKm: first)
            + CollectionsAggregator.estimatedHours(distanceKm: second)
        #expect(stats.totalFlights == 1)
        #expect(abs(stats.totalKm - (first + second)) < 0.001)
        #expect(abs(stats.totalEstimatedHours - hours) < 0.0001)
        #expect(abs(stats.longestKm - second) < 0.001)
        #expect(stats.longestRouteLabel == "QQC → QQB")
        // Journey-level marks count once.
        #expect(stats.internationalCount == 1)
        #expect(stats.timeZonesCrossedTotal == direct.timeZonesCrossed)
        #expect(abs(flight.journeyEstimatedHours - (hours + FlightStops.connectionHours)) < 0.0001)

        // The user's times stand in for the legs' estimate.
        let times = Times(departure: Self.at(6), arrival: Self.at(19))
        let timed = aggregate([leg.departure, leg.arrival], flightStops: [leg.arrival.id: ["QQC"]],
                              flightTimes: [leg.arrival.id: times])
        #expect(timed.flightStats.totalEstimatedHours == 13)
        #expect(timed.flightStats.totalFlights == 1)
    }

    @Test("most flown route counts legs")
    func mostFlownRouteCountsLegs() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let outbound = try flightLeg(in: context)
        // A second journey from Midwater to Eastmere, nonstop.
        let departure = makeStay(lat: 10.001, lon: 3.001, start: Self.at(100), end: Self.at(105))
        let arrival = makeStay(lat: 10.001, lon: 10.001, start: Self.at(110), end: Self.at(140),
                               transit: .flight)
        context.insert(departure)
        context.insert(arrival)
        try context.save()

        let stats = aggregate([outbound.departure, outbound.arrival, departure, arrival],
                              flightStops: [outbound.arrival.id: ["QQC"]]).flightStats
        #expect(stats.totalFlights == 2)
        #expect(stats.mostFlownRouteLabel == "QQB \u{2194} QQC")
        #expect(stats.mostFlownRouteCount == 2)
    }

    @Test("a stop airport joins the Airports list as flown through, a connection with no stay")
    func stopAirportsJoinTheCollection() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let leg = try flightLeg(in: context)

        let result = aggregate([leg.departure, leg.arrival], flightStops: [leg.arrival.id: ["QQC", "QQD"]])
        let flight = try #require(result.flights.first)
        #expect(result.flightStats.totalFlights == 1)
        let middle = try #require(result.airports.first { $0.code == "QQC" })
        #expect(middle.flownThrough)
        #expect(middle.stayCount == 0)
        #expect(middle.connectionCount == 1)
        #expect(middle.visitCount == 1)
        #expect(middle.firstVisit == flight.date && middle.lastVisit == flight.date)
        #expect(middle.name == "Midwater Airport" && middle.isoCountryCode == "CC")
        #expect(result.airports.contains { $0.code == "QQD" })
        // The ends keep their recorded visits.
        let origin = try #require(result.airports.first { $0.code == "QQA" })
        #expect(origin.stayCount == 1 && origin.connectionCount == 0)
    }

    @Test("stops that repeat an end, repeat each other, are unknown or unscheduled are left out")
    func unusableStopsAreDropped() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let leg = try flightLeg(in: context)

        let flight = try #require(aggregate(
            [leg.departure, leg.arrival],
            flightStops: [leg.arrival.id: ["QQA", "ZZZ", "QQF", "QQC", "QQC"]]).flights.first)
        #expect(flight.stops?.map(\.code) == ["QQC"])

        let reset = try #require(aggregate(
            [leg.departure, leg.arrival], flightStops: [leg.arrival.id: []]).flights.first)
        #expect(reset.stops == nil)
        #expect(reset.legs.count == 1)
    }

    @Test("a hop with no point shares what the measured hops leave of the journey")
    func unmeasuredHopTakesTheRemainder() {
        var record = CollectionsAggregator.FlightRecord(
            id: UUID(), departureCode: nil, arrivalCode: "QQB",
            departurePlace: "Westhaven", arrivalPlace: "Eastmere",
            departureISO: nil, arrivalISO: "BB", date: Self.at(10), distanceKm: 1_200,
            estimatedHours: CollectionsAggregator.estimatedHours(distanceKm: 1_200),
            isInternational: nil, timeZonesCrossed: 1, isOvernight: false,
            departureWindowStart: nil)
        record.arrivalLatitude = Self.east.lat
        record.arrivalLongitude = Self.east.lon
        record = record.applyingStops(["QQD"], resolve: Self.byCode)
        let legs = record.legs
        let measured = Self.km(Self.nearEast, Self.east)
        #expect(legs.count == 2)
        #expect(abs(legs[1].distanceKm - measured) < 0.001)
        #expect(abs(legs[0].distanceKm - (1_200 - measured)) < 0.001)
        #expect(legs[0].routeLabel == "Westhaven → QQD")
    }

    // MARK: When did you fly

    @Test("the answers to When did you fly sit at either end of a long window, a journey's estimate long")
    func whenDidYouFlyTimes() {
        let start = Self.at(0), end = Self.at(72)
        let after = FlightTimeOverrides.afterLeaving(windowStart: start, windowEnd: end, estimatedHours: 5)
        #expect(after == Times(departure: Self.at(0), arrival: Self.at(5)))
        #expect(FlightTimeOverrides.fits(after, windowStart: start, windowEnd: end))
        let before = FlightTimeOverrides.suggested(windowStart: start, windowEnd: end, estimatedHours: 5)
        #expect(before == Times(departure: Self.at(67), arrival: Self.at(72)))
        #expect(FlightTimeOverrides.fits(before, windowStart: start, windowEnd: end))

        // An estimate past the window lands at its end; one past the
        // longest duration is clamped.
        let short = FlightTimeOverrides.afterLeaving(windowStart: Self.at(0), windowEnd: Self.at(24), estimatedHours: 30)
        #expect(short == Times(departure: Self.at(0), arrival: Self.at(24)))
        let clamped = FlightTimeOverrides.afterLeaving(windowStart: Self.at(0), windowEnd: Self.at(100), estimatedHours: 80)
        #expect(clamped.duration == FlightTimeOverrides.maximumDuration)
        #expect(FlightTimeOverrides.questionMinimumGap == 24 * 60 * 60)
    }

    @Test("a tight window caps the legs' estimates, and they still add up to the journey's")
    func cappedLegsAddUp() {
        var flight = CollectionsAggregator.FlightRecord(
            id: UUID(), departureCode: "QQA", arrivalCode: "QQB", departurePlace: "Westhaven",
            arrivalPlace: "Eastmere", departureISO: "AA", arrivalISO: "BB", date: Self.at(6.5),
            distanceKm: 1_095, estimatedHours: CollectionsAggregator.estimatedHours(distanceKm: 1_095),
            isInternational: true, timeZonesCrossed: 1, isOvernight: false,
            departureWindowStart: Self.at(5), departureTimeZoneIdentifier: nil, arrivalTimeZoneIdentifier: nil)
        flight.departureLatitude = 10; flight.departureLongitude = 0
        flight.arrivalLatitude = 10; flight.arrivalLongitude = 10
        flight.stops = [.init(Self.middle)]
        #expect(flight.legs.count == 2 && flight.legsEstimatedHours > 1.5)
        #expect(abs(flight.estimatedAirHours - 1.5) < 0.0001 && flight.flightHours == flight.estimatedAirHours)
        let legs = flight.legs.reduce(0) { $0 + flight.estimatedAirHours(of: $1) }
        #expect(abs(legs - 1.5) < 0.0001)
    }

    @Test("the journey estimate behind the answers adds an hour per stop to the legs")
    func journeyEstimateWithStops() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let leg = try flightLeg(in: context, arrivalHour: 80)
        let flight = try #require(aggregate(
            [leg.departure, leg.arrival], flightStops: [leg.arrival.id: ["QQC"]]).flights.first)
        let estimate = flight.journeyEstimatedHours
        #expect(abs(estimate - (flight.legsEstimatedHours + 1)) < 0.0001)
        let windowStart = try #require(flight.departureWindowStart)
        let after = FlightTimeOverrides.afterLeaving(
            windowStart: windowStart, windowEnd: flight.date, estimatedHours: estimate)
        #expect(after.departure == windowStart)
        #expect(abs(after.duration - estimate * 3600) < 1)

        // Saved as the user's times, the log reads a single day.
        let applied = flight.applyingUserTimes(after)
        #expect(applied.userTimes == after)
    }

    // MARK: Snapshots

    @Test("a record and an airport from a snapshot written before stops decode as nonstop with no connection")
    func olderSnapshotDecodes() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let leg = try flightLeg(in: context)
        let result = aggregate([leg.departure, leg.arrival], flightStops: [leg.arrival.id: ["QQC"]])
        let flight = try #require(result.flights.first)
        let airport = try #require(result.airports.first { $0.code == "QQC" })

        var record = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(flight)) as? [String: Any])
        #expect(record["stops"] != nil)
        record["stops"] = nil
        let decoded = try JSONDecoder().decode(
            CollectionsAggregator.FlightRecord.self, from: JSONSerialization.data(withJSONObject: record))
        #expect(decoded.stops == nil)
        #expect(decoded.legs.count == 1)

        var entry = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(airport)) as? [String: Any])
        entry["connectionCount"] = nil
        let decodedEntry = try JSONDecoder().decode(
            CollectionsAggregator.AirportEntry.self, from: JSONSerialization.data(withJSONObject: entry))
        #expect(decodedEntry.connectionCount == 0)
        #expect(decodedEntry.code == "QQC")

        // A round trip keeps them.
        let roundTrip = try JSONDecoder().decode(
            CollectionsAggregator.Collections.self, from: JSONEncoder().encode(result))
        #expect(roundTrip.flights.first?.stops == flight.stops)
        #expect(roundTrip.airports == result.airports)
    }

    // MARK: Backup

    @Test("a restored backup adds stops this device lacks and never replaces its own, a nonstop included")
    func backupMergeKeepsThisDevicesStops() throws {
        let (defaults, suite) = try makeDefaults()
        let (ubiquitous, ubiquitousSuite) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suite)
            ubiquitous.removePersistentDomain(forName: ubiquitousSuite)
        }
        let kept = UUID(), nonstop = UUID(), added = UUID()
        FlightStops.set(["MUC"], for: kept, defaults: defaults)
        FlightStops.set([], for: nonstop, defaults: defaults)

        var preferences = BackupPreferences()
        preferences.flightStops = [
            FlightStops.entry(id: kept, codes: ["FRA"]),
            FlightStops.entry(id: nonstop, codes: ["IST"]),
            FlightStops.entry(id: added, codes: ["DOH", "SIN"]),
        ]
        #expect(BackupPreferences.restore(preferences, defaults: defaults, ubiquitous: ubiquitous) == 3)

        let all = FlightStops.all(defaults: defaults)
        #expect(all[kept] == ["MUC"])
        #expect(all[nonstop] == [])
        #expect(all[added] == ["DOH", "SIN"])
        #expect(BackupPreferences.current(defaults: defaults, ubiquitous: ubiquitous).flightStops?.count == 5)

        // A file written before stops existed decodes without them.
        let older = try JSONDecoder().decode(BackupPreferences.self, from: Data("{}".utf8))
        #expect(older.flightStops == nil)
    }
}
