//
//  FlightRouteOverrides.swift
//  TravelLog
//
//  The airports the user said a flight left from or landed at.
//

import Foundation

/// The ends of a flight, as the user set them in the Flight Log. Location
/// data names the place the user was first seen after landing, so a trip
/// with no fix at the airport (the first photo taken in a town an hour's
/// drive away) reads as a flight to wherever that was. An end set here replaces the
/// detected airport in the route, its distance and estimate, the countries
/// and the time zones; the journey's window, places and trips stay as the
/// data saw them. The airport joins the Airports list as flown through. No
/// stay or location point is made.
///
/// Keyed by the ARRIVAL stay's UUID, like `FlightStops`, and device-local
/// the same way: the backup's preferences carry it and Delete All Data
/// clears it. Stored as one string list, newest last
/// ("<uuid> <FROM> <TO>", "-" for an end left as detected), so the backup's
/// answer-list merge carries it; when the list names a flight twice, the
/// later entry wins. An entry with the UUID alone records a route reset to
/// the detected one: kept, rather than removed, so a restored file's older
/// route never comes back over it.
nonisolated enum FlightRouteOverrides {
    static let defaultsKey = "flightRoutes_v1"

    /// The codes the user set; nil leaves that end as detected.
    nonisolated struct Route: Sendable, Equatable, Codable {
        var departure: String?
        var arrival: String?

        init(departure: String? = nil, arrival: String? = nil) {
            self.departure = departure
            self.arrival = arrival
        }

        /// Neither end set: the detected route.
        var isEmpty: Bool { departure == nil && arrival == nil }
    }

    private static let unset = "-"

    // MARK: Storage

    /// Every flight's saved route; an empty one records a reset.
    static func all(defaults: UserDefaults = .standard) -> [UUID: Route] {
        var result: [UUID: Route] = [:]
        for entry in defaults.stringArray(forKey: defaultsKey) ?? [] {
            guard let parsed = parse(entry) else { continue }
            result[parsed.id] = parsed.route
        }
        return result
    }

    /// nil when the flight has no entry.
    static func route(for id: UUID, defaults: UserDefaults = .standard) -> Route? {
        all(defaults: defaults)[id]
    }

    /// Replaces the flight's entry (every earlier one for its id goes); an
    /// empty route records the reset.
    static func set(_ route: Route, for id: UUID, defaults: UserDefaults = .standard) {
        var raw = withoutEntries(for: id, defaults: defaults)
        raw.append(entry(id: id, route: route))
        defaults.set(raw, forKey: defaultsKey)
    }

    /// Forgets the flight's entry altogether. A user-facing reset uses
    /// `set(Route(), for:)` to retain its tombstone.
    static func clear(_ id: UUID, defaults: UserDefaults = .standard) {
        let raw = defaults.stringArray(forKey: defaultsKey) ?? []
        let kept = withoutEntries(for: id, defaults: defaults)
        guard kept.count != raw.count else { return }
        if kept.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(kept, forKey: defaultsKey)
        }
    }

    static func entry(id: UUID, route: Route) -> String {
        guard !route.isEmpty else { return id.uuidString }
        return [id.uuidString, route.departure ?? unset, route.arrival ?? unset].joined(separator: " ")
    }

    /// nil for an entry this build cannot read (a restored file is not
    /// trusted): every reader skips it.
    static func parse(_ entry: String) -> (id: UUID, route: Route)? {
        let parts = entry.split(separator: " ").map(String.init)
        guard parts.count == 1 || parts.count == 3,
              let id = UUID(uuidString: parts[0]) else { return nil }
        guard parts.count == 3 else { return (id, Route()) }
        func end(_ part: String) -> String?? {
            if part == unset { return .some(nil) }
            return FlightStops.isCode(part) ? .some(part) : nil
        }
        guard let departure = end(parts[1]), let arrival = end(parts[2]),
              departure == nil || departure != arrival else { return nil }
        return (id, Route(departure: departure, arrival: arrival))
    }

    private static func withoutEntries(for id: UUID, defaults: UserDefaults) -> [String] {
        let key = id.uuidString
        return (defaults.stringArray(forKey: defaultsKey) ?? []).filter {
            $0 != key && !$0.hasPrefix(key + " ")
        }
    }

    // MARK: Suggestions

    /// How far from an end's point an airport is offered as that end.
    static let nearbyRadiusKm: Double = 200
    static let suggestionLimit = 6

    /// Scheduled airports near an end's point, nearest first, leaving out
    /// `excluding` (the codes already on the route).
    static func nearby(
        latitude: Double, longitude: Double, excluding: Set<String>,
        airports: [AirportRecord], limit: Int = suggestionLimit
    ) -> [AirportRecord] {
        guard latitude.isFinite, longitude.isFinite else { return [] }
        var ranked: [(airport: AirportRecord, km: Double)] = []
        for airport in airports where airport.svc != false && FlightStops.isCode(airport.code)
            && !excluding.contains(airport.code) {
            let km = CollectionsAggregator.haversineKm(
                lat1: latitude, lon1: longitude, lat2: airport.lat, lon2: airport.lon)
            if km <= nearbyRadiusKm { ranked.append((airport, km)) }
        }
        return ranked
            .sorted {
                if $0.km != $1.km { return $0.km < $1.km }
                return $0.airport.code < $1.airport.code
            }
            .prefix(limit)
            .map { $0.airport }
    }
}
