//
//  CollectionsDisplay.swift
//  TravelLog
//
//  What the Collections pages draw beyond the aggregate's own values,
//  derived once per input: the flight totals' years, places, routes and
//  records; the Airports page's country cards and regions; the Places
//  page's kinds, countries and new places. Pure values over
//  `CollectionsAggregator`'s results, so the pages only lay them out.
//

import Foundation

// MARK: - Flight totals

/// The Flight Log totals sheet's figures over the selected flights.
nonisolated struct FlightTotalsSummary: Sendable, Equatable {
    typealias Flight = CollectionsAggregator.FlightRecord

    /// A place the flights touch: an airport by its code, else the place
    /// the data named.
    struct Station: Sendable, Equatable, Identifiable {
        /// The code, or the place name for an end with no airport.
        let id: String
        let code: String?
        /// The airport's name, else the place's.
        let name: String
        let city: String?
        let isoCountryCode: String?
        /// nil when the record carries no point for it.
        let latitude: Double?
        let longitude: Double?
        /// Recorded journeys through it, each once.
        var flights: Int
        /// The year of its first journey.
        var firstYear: Int?
    }

    /// A pair of stations flown between, either way.
    struct Route: Sendable, Equatable {
        /// Station ids, in ascending order.
        let from: String
        let to: String
        var flights: Int
    }

    /// One end of a record, as its ticket shows it.
    struct End: Sendable, Equatable {
        /// The code, else the place name.
        let label: String
        let city: String?
        let isoCountryCode: String?
    }

    /// A single hop: the longest or the shortest flown.
    struct Hop: Sendable, Equatable {
        let from: End
        let to: End
        let distanceKm: Double
        /// The block-time estimate over its distance.
        let estimatedHours: Double
    }

    /// The route flown most, both ways.
    struct FrequentRoute: Sendable, Equatable {
        let first: End
        let second: End
        let flights: Int
    }

    struct YearCount: Sendable, Equatable {
        let year: Int
        let flights: Int
    }

    /// Every year from the first flight's to the current one (or the last
    /// flight's, if later), oldest first; a year without flights counts 0.
    var years: [YearCount] = []
    /// Most flights first, then by id.
    var stations: [Station] = []
    /// Least flown first, so the busiest draw on top.
    var routes: [Route] = []
    var longest: Hop?
    /// nil with fewer than two hops of known distance.
    var shortest: Hop?
    /// nil unless some route was flown at least twice.
    var mostFlown: FrequentRoute?

    /// The stations that are airports, busiest first.
    var airports: [Station] { stations.filter { $0.code != nil } }

    /// The resolver for an airport's city and missing name and country.
    typealias AirportLookup = (String) -> AirportRecord?

    init() {}

    init(_ flights: [Flight], currentYear: Int,
         airport: AirportLookup = { AirportDetector.shared.airport(code: $0) }) {
        var stationIndex: [String: Int] = [:]
        var routeCounts: [String: Route] = [:]
        var codeRouteCounts: [String: Int] = [:]
        var yearCounts: [Int: Int] = [:]
        var hops: [Hop] = []

        for flight in flights {
            let year = FlightLogProjection.year(of: flight)
            if let year { yearCounts[year, default: 0] += 1 }
            let points = Self.points(of: flight, airport: airport)

            var touched: Set<String> = []
            for point in points where touched.insert(point.station.id).inserted {
                if let index = stationIndex[point.station.id] {
                    stations[index].flights += 1
                    if let year, year < stations[index].firstYear ?? .max { stations[index].firstYear = year }
                } else {
                    var station = point.station
                    station.firstYear = year
                    stationIndex[station.id] = stations.count
                    stations.append(station)
                }
            }

            // `legs` hops through the same points, one per pair.
            let legs = flight.legs
            guard legs.count == points.count - 1 else { continue }
            for (leg, pair) in zip(legs, zip(points, points.dropFirst())) {
                let (from, to) = pair
                if leg.distanceKm.isFinite, leg.distanceKm > 0 {
                    hops.append(Hop(from: from.end, to: to.end, distanceKm: leg.distanceKm,
                                    estimatedHours: leg.estimatedHours))
                }
                if from.station.id != to.station.id {
                    let ids = [from.station.id, to.station.id].sorted()
                    routeCounts[ids.joined(separator: "\u{1F}"), default: Route(from: ids[0], to: ids[1], flights: 0)]
                        .flights += 1
                }
                // Codes only, as `flightStats` keys its most flown route.
                if let a = from.station.code, let b = to.station.code, a != b {
                    codeRouteCounts[[a, b].sorted().joined(separator: "\u{1F}"), default: 0] += 1
                }
            }
        }

        stations.sort { $0.flights != $1.flights ? $0.flights > $1.flights : $0.id < $1.id }
        routes = routeCounts.values.sorted {
            $0.flights != $1.flights ? $0.flights < $1.flights : ($0.from, $0.to) < ($1.from, $1.to)
        }
        // The first of equals wins, in the log's order.
        longest = hops.reduce(nil) { best, hop in hop.distanceKm > (best?.distanceKm ?? 0) ? hop : best }
        if hops.count > 1 {
            shortest = hops.reduce(nil) { best, hop in hop.distanceKm < (best?.distanceKm ?? .infinity) ? hop : best }
        }
        // Count desc, then key asc, so equal routes never swap between launches.
        if let top = codeRouteCounts.max(by: { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
        }), top.value > 1 {
            let codes = top.key.split(separator: "\u{1F}").map(String.init)
            let ends = codes.map { code in
                let station = stations.first { $0.id == code }
                return End(label: code, city: station?.city, isoCountryCode: station?.isoCountryCode)
            }
            mostFlown = FrequentRoute(first: ends[0], second: ends[1], flights: top.value)
        }
        if let first = yearCounts.keys.min(), let last = yearCounts.keys.max() {
            years = (first...max(last, currentYear)).map { YearCount(year: $0, flights: yearCounts[$0] ?? 0) }
        }
    }

    /// The record's points in route order: departure, stops, arrival;
    /// an end with neither a code nor a place is left out.
    private static func points(of flight: Flight, airport: AirportLookup)
        -> [(station: Station, end: End)] {
        typealias Raw = (code: String?, place: String?, name: String?, city: String?,
                         iso: String?, latitude: Double?, longitude: Double?)
        var raw: [Raw] = [(flight.departureCode, flight.departurePlace, flight.departureAirportName, nil,
                           flight.departureISO, flight.departureLatitude, flight.departureLongitude)]
        for stop in flight.stops ?? [] {
            raw.append((stop.code, nil, stop.name, stop.city, stop.isoCountryCode, stop.latitude, stop.longitude))
        }
        raw.append((flight.arrivalCode, flight.arrivalPlace, flight.arrivalAirportName, nil,
                    flight.arrivalISO, flight.arrivalLatitude, flight.arrivalLongitude))
        return raw.compactMap { point in
            guard let id = point.code ?? point.place else { return nil }
            let record = point.code.flatMap(airport)
            let iso = (point.iso ?? record?.iso)?.uppercased()
            let city = point.city ?? record?.city
            let hasPoint = point.latitude?.isFinite == true && point.longitude?.isFinite == true
            let station = Station(
                id: id, code: point.code, name: point.name ?? record?.name ?? point.place ?? id,
                city: city, isoCountryCode: iso,
                latitude: hasPoint ? point.latitude : nil, longitude: hasPoint ? point.longitude : nil,
                flights: 1, firstYear: nil)
            // A place end is its own city.
            return (station, End(label: id, city: point.code == nil ? nil : city, isoCountryCode: iso))
        }
    }

    // MARK: Around the Earth

    /// The Earth's equatorial circumference, the "around the Earth" unit.
    static let earthCircumferenceKm = 40_075.0

    /// One entry per lap of the Earth `km` makes: 1 for each whole lap,
    /// then how far the last one got (0 to 1); empty for no distance. A
    /// last lap under a hundredth adds nothing after whole ones.
    static func laps(km: Double) -> [Double] {
        guard km.isFinite, km > 0 else { return [] }
        let laps = km / earthCircumferenceKm
        let whole = Int(laps.rounded(.down))
        let rest = laps - Double(whole)
        var result = Array(repeating: 1.0, count: whole)
        if whole == 0 || rest >= 0.01 { result.append(rest) }
        return result
    }

    // MARK: Year bars

    /// The busiest year (the latest of equals); nil without flights.
    var busiestYear: YearCount? {
        years.filter { $0.flights > 0 }.max { $0.flights != $1.flights ? $0.flights < $1.flights : $0.year < $1.year }
    }
}

// MARK: - Airports

nonisolated enum AirportsDisplay {
    typealias Airport = CollectionsAggregator.AirportEntry

    /// One country's airports, as its card lists them.
    struct CountryCard: Sendable, Equatable, Identifiable {
        /// Uppercased; nil for airports in no known country.
        let isoCountryCode: String?
        /// Most visited first, then by code.
        let airports: [Airport]
        var id: String { isoCountryCode ?? "" }
        var visits: Int { airports.reduce(0) { $0 + $1.visitCount } }
        var flownCount: Int { airports.count(where: \.flownThrough) }
    }

    /// Countries by their airports' visits, most first, then by code; the
    /// airports in no known country last.
    static func countryCards(_ airports: [Airport]) -> [CountryCard] {
        let groups = Dictionary(grouping: airports) { airport -> String? in
            guard let iso = airport.isoCountryCode?.uppercased(), !iso.isEmpty else { return nil }
            return iso
        }
        return groups.map { iso, airports in
            CountryCard(isoCountryCode: iso, airports: airports.sorted {
                $0.visitCount != $1.visitCount ? $0.visitCount > $1.visitCount : $0.code < $1.code
            })
        }
        .sorted { lhs, rhs in
            if (lhs.isoCountryCode == nil) != (rhs.isoCountryCode == nil) { return rhs.isoCountryCode == nil }
            if lhs.visits != rhs.visits { return lhs.visits > rhs.visits }
            return (lhs.isoCountryCode ?? "") < (rhs.isoCountryCode ?? "")
        }
    }

    /// The continents (`PassportContinents`) holding the airports, most
    /// visits first, ties by code.
    static func continents(_ airports: [Airport]) -> [String] {
        var visits: [String: Int] = [:]
        for airport in airports {
            guard let continent = continent(of: airport) else { continue }
            visits[continent, default: 0] += airport.visitCount
        }
        return visits.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    /// The region the map opens on: the busiest continent; nil (the world)
    /// when the airports lie in one continent or fewer, where a region
    /// would only repeat it.
    static func region(_ airports: [Airport]) -> String? {
        let continents = continents(airports)
        return continents.count > 1 ? continents.first : nil
    }

    static func continent(of airport: Airport) -> String? {
        airport.isoCountryCode.flatMap(PassportContinents.continent(of:))
    }

    /// The UN M49 code a continent's name reads under (`Locale`'s region
    /// names): the Americas' halves have their own.
    static func regionCode(forContinent continent: String) -> String {
        switch continent {
        case "NA": "003"
        case "SA": "005"
        default: continent
        }
    }
}

// MARK: - Places

nonisolated enum PlacesDisplay {
    typealias Place = CollectionsAggregator.PlaceEntry
    typealias Kind = CollectionsAggregator.PlaceKind

    /// The filter chips' order.
    static let kinds: [Kind] = [.metro, .locality, .island, .area]

    struct KindCount: Sendable, Equatable {
        let kind: Kind
        let count: Int
    }

    /// The kinds present, in chip order, with their places.
    static func kindCounts(_ places: [Place]) -> [KindCount] {
        kinds.compactMap { kind in
            let count = places.count { $0.kind == kind }
            return count > 0 ? KindCount(kind: kind, count: count) : nil
        }
    }

    /// Countries by ISO code, else by the stored name; a place in no known
    /// country adds none.
    static func countryCount(_ places: [Place]) -> Int {
        Set(places.compactMap { place -> String? in
            if let iso = place.isoCountryCode?.uppercased(), !iso.isEmpty { return iso }
            return place.country.map { "name:" + $0 }
        }).count
    }

    /// Places first visited in `now`'s calendar year, newest first.
    static func newThisYear(_ places: [Place], now: Date = .now, calendar: Calendar = .current) -> [Place] {
        let year = calendar.component(.year, from: now)
        return places
            .filter { calendar.component(.year, from: $0.firstVisit) == year }
            .sorted { $0.firstVisit != $1.firstVisit ? $0.firstVisit > $1.firstVisit : $0.id < $1.id }
    }
}
