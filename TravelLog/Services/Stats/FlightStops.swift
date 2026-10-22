//
//  FlightStops.swift
//  TravelLog
//
//  The connections the user added to a flight in the Flight Log.
//

import Foundation

/// The airports a flight connected through, as the user set them. Location
/// data sees a flight only between the last fix at the origin and the first
/// at the destination, so a connection where nothing was recorded (Athens to
/// Frankfurt to Los Angeles) reads as one nonstop. Stops set here split the
/// flight into legs (`FlightRecord.legs`): each leg counts as a flight in
/// the totals, with its own distance and estimate, and the stop airports
/// join the Airports list as flown through. Nothing else moves: no stay or
/// location point is made, and trips never see them.
///
/// Keyed by the ARRIVAL stay's UUID, like `FlightTimeOverrides`, and
/// device-local the same way: the backup's preferences carry it and Delete
/// All Data clears it. Stored as one string list, newest last
/// ("<uuid> <CODE> <CODE>"), so the backup's answer-list merge carries it;
/// when the list names a flight twice, the later entry wins. An entry with
/// the uuid alone is the user's own nonstop: kept, rather than removed, so
/// a restored file's older stops never come back over it.
nonisolated enum FlightStops {
    static let defaultsKey = "flightStops_v1"

    /// Two connections cover nearly every itinerary a traveller books.
    static let maximumStops = 2
    /// The connection's own time on the ground, for the journey estimate
    /// the "When did you fly?" answers use.
    static let connectionHours: Double = 1

    // MARK: Storage

    /// Every flight's stops, in order; an empty list is a nonstop the user
    /// set back.
    static func all(defaults: UserDefaults = .standard) -> [UUID: [String]] {
        var result: [UUID: [String]] = [:]
        for entry in defaults.stringArray(forKey: defaultsKey) ?? [] {
            guard let parsed = parse(entry) else { continue }
            result[parsed.id] = parsed.codes
        }
        return result
    }

    /// nil when the flight has no entry.
    static func stops(for id: UUID, defaults: UserDefaults = .standard) -> [String]? {
        all(defaults: defaults)[id]
    }

    /// Replaces the flight's entry (every earlier one for its id goes); an
    /// empty list records the nonstop.
    static func set(_ codes: [String], for id: UUID, defaults: UserDefaults = .standard) {
        var raw = withoutEntries(for: id, defaults: defaults)
        raw.append(entry(id: id, codes: codes))
        defaults.set(raw, forKey: defaultsKey)
    }

    /// Forgets the flight's entry altogether (a confirm that failed to save
    /// puts back what was there).
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

    static func entry(id: UUID, codes: [String]) -> String {
        ([id.uuidString] + codes.prefix(maximumStops)).joined(separator: " ")
    }

    /// nil for an entry this build cannot read (a restored file is not
    /// trusted): every reader skips it.
    static func parse(_ entry: String) -> (id: UUID, codes: [String])? {
        let parts = entry.split(separator: " ")
        guard (1...(1 + maximumStops)).contains(parts.count),
              let id = UUID(uuidString: String(parts[0])) else { return nil }
        let codes = parts.dropFirst().map(String.init)
        guard codes.allSatisfy(isCode) else { return nil }
        return (id, codes)
    }

    /// An IATA code: three capital letters or digits.
    static func isCode(_ code: String) -> Bool {
        code.count == 3 && code.unicodeScalars.allSatisfy {
            ("A"..."Z").contains($0) || ("0"..."9").contains($0)
        }
    }

    private static func withoutEntries(for id: UUID, defaults: UserDefaults) -> [String] {
        let key = id.uuidString
        return (defaults.stringArray(forKey: defaultsKey) ?? []).filter {
            $0 != key && !$0.hasPrefix(key + " ")
        }
    }

    // MARK: Suggestions

    /// Major connecting hubs worldwide, the suggestions after the airports
    /// the user has been to. Only codes in the bundled dataset ever show.
    static let hubCodes = [
        "FRA", "MUC", "LHR", "CDG", "AMS", "ZRH", "VIE", "IST", "BRU", "CPH",
        "ARN", "HEL", "MAD", "BCN", "FCO", "LIS", "DUB", "WAW", "ATH", "DXB",
        "DOH", "AUH", "JED", "CAI", "ADD", "NBO", "JNB", "DEL", "BOM", "SIN",
        "KUL", "BKK", "HKG", "TPE", "MNL", "CGK", "ICN", "NRT", "HND", "PEK",
        "PVG", "CAN", "SYD", "MEL", "AKL", "JFK", "EWR", "BOS", "IAD", "ATL",
        "MIA", "CLT", "ORD", "DFW", "IAH", "DEN", "PHX", "LAX", "SFO", "SEA",
        "YYZ", "YUL", "YVR", "MEX", "PTY", "BOG", "LIM", "SCL", "GRU",
    ]
    /// A stop is "on the way" when going through it is at most this much
    /// longer than flying direct.
    static let detourAllowance = 1.2
    /// Airports this close to either end are that end's own, never a
    /// connection.
    static let endpointExclusionKm: Double = 50
    static let suggestionLimit = 6

    /// Airports roughly on the way from one point to another: the airports
    /// the user has been to first, then the hubs, each group by how little
    /// it adds to the direct distance. `excluding` holds the codes already
    /// on the route (its ends and earlier stops).
    static func suggestions(
        fromLatitude: Double, fromLongitude: Double,
        toLatitude: Double, toLongitude: Double,
        excluding: Set<String>,
        visited: [String],
        hubs: [String] = hubCodes,
        resolve: (String) -> AirportRecord?,
        limit: Int = suggestionLimit
    ) -> [AirportRecord] {
        let direct = CollectionsAggregator.haversineKm(
            lat1: fromLatitude, lon1: fromLongitude, lat2: toLatitude, lon2: toLongitude)
        guard direct.isFinite, direct > 0 else { return [] }
        var seen = excluding
        var ranked: [(airport: AirportRecord, isVisited: Bool, detour: Double)] = []
        for (codes, isVisited) in [(visited, true), (hubs, false)] {
            for code in codes where seen.insert(code).inserted {
                guard isCode(code), let airport = resolve(code), airport.svc != false else { continue }
                let first = CollectionsAggregator.haversineKm(
                    lat1: fromLatitude, lon1: fromLongitude, lat2: airport.lat, lon2: airport.lon)
                let second = CollectionsAggregator.haversineKm(
                    lat1: airport.lat, lon1: airport.lon, lat2: toLatitude, lon2: toLongitude)
                guard first >= endpointExclusionKm, second >= endpointExclusionKm,
                      first + second <= detourAllowance * direct else { continue }
                ranked.append((airport, isVisited, first + second - direct))
            }
        }
        return ranked
            .sorted {
                if $0.isVisited != $1.isVisited { return $0.isVisited }
                if $0.detour != $1.detour { return $0.detour < $1.detour }
                return $0.airport.code < $1.airport.code
            }
            .prefix(limit)
            .map { $0.airport }
    }

    // MARK: Search

    /// The airports a stop can be: scheduled service and an IATA code, with
    /// their names folded once for matching.
    nonisolated struct SearchIndex: Sendable {
        fileprivate nonisolated struct Entry: Sendable {
            let airport: AirportRecord
            let code: String
            let name: String
            let city: String
        }
        fileprivate let entries: [Entry]

        init(_ airports: [AirportRecord]) {
            entries = airports
                .filter { $0.svc != false && FlightStops.isCode($0.code) }
                .map { Entry(airport: $0, code: FlightStops.fold($0.code),
                             name: FlightStops.fold($0.name ?? ""), city: FlightStops.fold($0.city ?? "")) }
        }
    }

    static let searchLimit = 8

    /// Airports matching the query by code, city or name: the exact code
    /// first, then codes, cities and names it begins (or begins a word of),
    /// then those that merely contain it.
    static func search(_ query: String, in index: SearchIndex, limit: Int = searchLimit) -> [AirportRecord] {
        let term = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !term.isEmpty else { return [] }
        func startsWord(_ text: String) -> Bool {
            text.hasPrefix(term) || text.contains(" " + term) || text.contains("-" + term)
                || text.contains("(" + term)
        }
        var ranked: [(airport: AirportRecord, rank: Int, name: String)] = []
        for entry in index.entries {
            let rank: Int
            if entry.code == term {
                rank = 0
            } else if term.count < 3, entry.code.hasPrefix(term) {
                rank = 1
            } else if startsWord(entry.city) {
                rank = 2
            } else if startsWord(entry.name) {
                rank = 3
            } else if term.count >= 3, entry.city.contains(term) || entry.name.contains(term) {
                rank = 4
            } else {
                continue
            }
            ranked.append((entry.airport, rank, entry.name))
        }
        return ranked
            .sorted {
                if $0.rank != $1.rank { return $0.rank < $1.rank }
                if $0.name != $1.name { return $0.name < $1.name }
                return $0.airport.code < $1.airport.code
            }
            .prefix(limit)
            .map { $0.airport }
    }

    fileprivate static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
