//
//  FlightLogProjection.swift
//  TravelLog
//
//  One pure projection for the journal, map and summary. The caller first
//  applies the existing stops/times corrections, then passes that same set
//  here. Candidates are searchable review items, never flown statistics.
//

import Foundation

nonisolated enum FlightLogProjection {
    typealias Flight = CollectionsAggregator.FlightRecord
    typealias Candidate = CollectionsAggregator.PossibleFlight

    nonisolated struct Snapshot: Sendable {
        let records: [Flight]
        let candidates: [Candidate]
        let sections: [Section]
        let summary: Summary
    }

    nonisolated struct Section: Sendable, Identifiable {
        let id: String
        /// nil is the explicitly uncertain-date section, shown in All Years.
        let year: Int?
        let flights: [Flight]
    }

    /// Derived endpoint keys for one projection. Array alignment, rather
    /// than UUID lookup, keeps physical UUID twins from aliasing geography.
    nonisolated struct GeographicIdentity: Sendable, Equatable {
        let departure: String?
        let arrival: String?
    }

    nonisolated struct Summary: Sendable {
        let journeyCount: Int
        let routeCount: Int
        /// Journeys whose endpoints can establish a geographic route.
        let routeJourneyCount: Int
        let estimatedKm: Double
        /// Journeys with a usable distance; the UI can disclose coverage.
        let distanceJourneyCount: Int
        let mostRecordedRoute: String?
        let mostRecordedRouteCount: Int
    }

    static func make(
        flights: [Flight], candidates: [Candidate], year: Int?, search: String,
        onlyUncertainDates: Bool = false
    ) -> Snapshot {
        let tokens = searchTokens(search)
        func includes(_ flight: Flight) -> Bool {
            let recordedYear = self.year(of: flight)
            if onlyUncertainDates && recordedYear != nil { return false }
            if let year, recordedYear != year { return false }
            let haystack = searchText(flight)
            return tokens.allSatisfy { haystack.contains($0) }
        }
        let visible = flights.filter(includes).sorted(by: newestFirst)
        let pending = candidates.filter { includes($0.record) }.sorted {
            newestFirst($0.record, $1.record)
        }
        let grouped = Dictionary(grouping: visible, by: { self.year(of: $0) })
        let knownYears = grouped.keys.compactMap { $0 }.sorted(by: >)
        var sections = knownYears.map { value in
            Section(id: "year-\(value)", year: value, flights: grouped[value] ?? [])
        }
        if let uncertain = grouped[nil], !uncertain.isEmpty {
            sections.append(Section(id: "uncertain-dates", year: nil, flights: uncertain))
        }
        return Snapshot(records: visible, candidates: pending, sections: sections,
                        summary: summarize(visible))
    }

    static func years(in flights: [Flight], candidates: [Candidate]) -> [Int] {
        Set((flights + candidates.map(\.record)).compactMap { year(of: $0) }).sorted(by: >)
    }

    /// A flight belongs to a year only when every possible civil date in its
    /// original observation window belongs to that year. User-entered legacy
    /// clock values have no precision provenance, so they never repair this.
    static func year(of flight: Flight) -> Int? {
        guard flight.observationDateQualityRaw == Flight.ObservationDateQuality.observedWindow.rawValue,
              let departureSource = flight.departureSourceRaw,
              let arrivalSource = flight.arrivalSourceRaw,
              DataSource(rawValue: departureSource) != nil,
              DataSource(rawValue: arrivalSource) != nil,
              flight.effectiveSourceRaws.allSatisfy({ DataSource(rawValue: $0) != nil }),
              let start = flight.departureWindowStart,
              validWindow(start: start, end: flight.date) else { return nil }
        // The detector already allows this clock uncertainty for photo-like
        // timestamps. Carry the same margin into year membership rather than
        // turning a 00:05 imported observation into an exact calendar year.
        // Missing retained members cannot prove clock purity, but a bounded
        // interval wholly within one year can still establish that year.
        // UUID collisions affect portable corrections, not physical dates.
        let needsTimeCaution = flight.sourceEvidenceComplete != true
            || (flight.observationNeedsTimeCaution ?? true)
            || flight.effectiveSourceRaws.contains { DataSource.needsPhotoTimeCaution(rawValue: $0) }
        let clockSlack = needsTimeCaution ? FlightJudge.photoClockSlackSeconds : 0
        // Current records already carry the retained origin observation.
        // Older snapshots only have a stay end that can extend into silence;
        // include that possible origin span until aggregation replaces it.
        var earliestOrigin = start
        if let observed = flight.departureLastObservedAt,
           validWindow(start: observed, end: flight.date) {
            earliestOrigin = min(start, observed)
        } else {
            // Current records carry the retained origin observation. Older
            // snapshots only have the extended stay boundary, so retain the
            // wider legacy interval until aggregation replaces them.
            earliestOrigin = start.addingTimeInterval(-FlightJudge.stayExtensionCapSeconds)
            if let stayStart = flight.departureStayStart,
               validWindow(start: stayStart, end: start) {
                earliestOrigin = max(earliestOrigin, stayStart)
            }
        }
        let lowerBound = earliestOrigin.addingTimeInterval(-clockSlack)
        let upperBound = flight.date.addingTimeInterval(clockSlack)
        // Absolute time order does not imply civil-year order across the
        // date line. Either endpoint zone may put either bound in another
        // year, so check all four corners of the uncertainty interval.
        let possible = Set([flight.departureTimeZoneIdentifier, flight.arrivalTimeZoneIdentifier]
            .flatMap { zone in
                civilYears(at: lowerBound, zoneIdentifier: zone)
                    + civilYears(at: upperBound, zoneIdentifier: zone)
            })
        return possible.count == 1 ? possible.first : nil
    }

    /// Place-first journal route, with only the connections supplied by the
    /// user. Missing connections do not assert a nonstop flight.
    static func primaryRoute(_ flight: Flight) -> String {
        Flight.route(endpointLabel(place: flight.departurePlace, code: flight.departureCode),
                     through: flight.stops?.map { nonempty($0.city) ?? $0.code } ?? [],
                     to: endpointLabel(place: flight.arrivalPlace, code: flight.arrivalCode))
    }

    static func searchText(_ flight: Flight) -> String {
        var fields = [flight.departurePlace, flight.arrivalPlace,
                      flight.departureCode, flight.arrivalCode,
                      flight.departureAirportName, flight.arrivalAirportName,
                      flight.departureISO, flight.arrivalISO].compactMap { $0 }
        for stop in flight.stops ?? [] {
            fields.append(contentsOf: [stop.code, stop.name, stop.city, stop.isoCountryCode].compactMap { $0 })
        }
        return normalizedSearch(fields.joined(separator: " "))
    }

    /// Resolves geography over the complete visible input once. Labels are
    /// candidate matches, never sufficient identity: homonyms and coarse
    /// country fallbacks are split into bounded geographic clusters.
    static func geographicIdentities(for flights: [Flight]) -> [GeographicIdentity] {
        let endpoints = flights.flatMap { flight in
            [geographicEndpoint(flight, departure: true), geographicEndpoint(flight, departure: false)]
        }
        let identities = FlightGeographicIdentity.resolve(endpoints)
        return flights.indices.map { index in
            GeographicIdentity(departure: identities[index * 2], arrival: identities[index * 2 + 1])
        }
    }

    /// Bidirectional route identity, including the complete recorded stop
    /// sequence. Pass the contextual identity when projecting several flights
    /// so nearby repeat visits share a key independently of input ordering.
    static func stableRouteIdentity(_ flight: Flight, geographicIdentity: GeographicIdentity? = nil) -> String? {
        let geography = geographicIdentity ?? geographicIdentities(for: [flight])[0]
        guard let from = geography.departure, let to = geography.arrival else { return nil }
        let stops = (flight.stops ?? []).map { "airport:" + $0.code.uppercased(with: Locale(identifier: "en_US_POSIX")) }
        let points = [from] + stops + [to]
        let forward = encoded(points)
        let reverse = encoded(points.reversed())
        return min(forward, reverse)
    }

    private static func geographicEndpoint(_ flight: Flight, departure: Bool) -> FlightGeographicIdentity.Endpoint {
        FlightGeographicIdentity.Endpoint(
            place: departure ? flight.departurePlace : flight.arrivalPlace,
            iso: departure ? flight.departureISO : flight.arrivalISO,
            administrativeArea: departure ? flight.departureAdministrativeArea : flight.arrivalAdministrativeArea,
            granularity: departure ? flight.departurePlaceGranularityRaw : flight.arrivalPlaceGranularityRaw,
            latitude: departure ? flight.flightLogDepartureLatitude : flight.flightLogArrivalLatitude,
            longitude: departure ? flight.flightLogDepartureLongitude : flight.flightLogArrivalLongitude,
            observedAirportCode: departure
                ? (flight.departureAirportResolution == .observedNearby ? flight.departureCode : nil)
                : (flight.arrivalAirportResolution == .observedNearby ? flight.arrivalCode : nil))
    }

    /// Uses the same observed/airport points as the offline schematic map.
    /// Unknown stops cannot be reconstructed; this remains a route estimate.
    static func estimatedDistanceKm(for flight: Flight) -> Double? {
        guard flight.distanceKm.isFinite, flight.distanceKm >= 0 else { return nil }
        let from = coordinate(flight.flightLogDepartureLatitude, flight.flightLogDepartureLongitude)
        let to = coordinate(flight.flightLogArrivalLatitude, flight.flightLogArrivalLongitude)
        guard let from, let to else {
            // A partial restore can retain a measured end-to-end distance
            // without endpoint geometry. Never split it into invented hops.
            return flight.stops?.isEmpty == false || flight.distanceKm == 0 ? nil : flight.distanceKm
        }
        var points = [from]
        for stop in flight.stops ?? [] {
            guard let point = coordinate(stop.latitude, stop.longitude) else { return nil }
            points.append(point)
        }
        points.append(to)
        let km = zip(points, points.dropFirst()).reduce(0.0) { sum, hop in
            sum + haversineKm(hop.0, hop.1)
        }
        return km.isFinite && km > 0 ? km : nil
    }

    static func dateText(_ flight: Flight) -> String {
        guard flight.date.timeIntervalSinceReferenceDate.isFinite else {
            return String(localized: "collections.flight-log.date-uncertain", defaultValue: "Date uncertain", comment: "Flight journal date whose observations cannot establish a date.")
        }
        let arrivalZone = TimeZone(identifier: flight.arrivalTimeZoneIdentifier ?? "")
            ?? TimeZone(secondsFromGMT: 0)!
        let arrival = dayText(flight.date, zone: arrivalZone)
        guard let start = flight.departureWindowStart, validWindow(start: start, end: flight.date) else {
            return arrival
        }
        let departureZone = TimeZone(identifier: flight.departureTimeZoneIdentifier ?? "")
            ?? TimeZone(secondsFromGMT: 0)!
        let departure = dayText(start, zone: departureZone)
        let departureDay = civilDayNumber(start, zone: departureZone)
        let arrivalDay = civilDayNumber(flight.date, zone: arrivalZone)
        guard departureDay != arrivalDay else { return arrival }
        if departureDay > arrivalDay {
            return String(localized: "collections.flight-date.reversed", defaultValue: "\(departure) → \(arrival)", comment: "Flight dates when the arrival's local date is earlier than the departure's (crossing the date line): departure date, then arrival date.")
        }
        return String(localized: "collections.flight-log.observed-range", defaultValue: "\(departure) – \(arrival)", comment: "Flight journal observation date range, from the last origin observation to the first destination observation. These are not flight times.")
    }

    static func uncertaintyHint(_ flight: Flight) -> String? {
        if year(of: flight) == nil {
            return String(localized: "collections.flight-log.date-uncertain", defaultValue: "Date uncertain", comment: "Flight journal date whose observations cannot establish a date.")
        }
        if let start = flight.departureWindowStart, flight.date.timeIntervalSince(start) >= 86_400 {
            return String(localized: "collections.flight-log.observation-window", defaultValue: "Observed date range", comment: "Flight journal note: the route is known only within a range between observations.")
        }
        let sources = flight.effectiveSourceRaws.compactMap(DataSource.init(rawValue:))
        if sources.contains(.merged) || Set(sources.map(\.derivedRecordSource)).count > 1 {
            return String(localized: "collections.flight-log.source.mixed", defaultValue: "Mixed observations", comment: "Compact flight journal note for a journey supported by mixed acquisition sources, including potentially photos.")
        }
        if sources.contains(.photoImport) {
            return String(localized: "collections.flight-log.source.photos", defaultValue: "Photo observations", comment: "Compact flight journal note for a journey inferred from photo metadata, which cannot verify passenger identity or boarding.")
        }
        if sources.contains(where: { !$0.isLiveObservation }) {
            return String(localized: "collections.flight-log.source.imported", defaultValue: "Imported observations", comment: "Compact flight journal note for a journey supported by imported observations rather than only live tracking.")
        }
        return nil
    }

    private static func summarize(_ flights: [Flight]) -> Summary {
        var routes: [String: (count: Int, label: String)] = [:]
        var kilometers = 0.0
        var distanceCount = 0
        var routeJourneyCount = 0
        let identities = geographicIdentities(for: flights)
        for (flight, geography) in zip(flights, identities) {
            if let key = stableRouteIdentity(flight, geographicIdentity: geography) {
                routeJourneyCount += 1
                let label = canonicalRouteLabel(flight)
                let previous = routes[key]
                routes[key] = ((previous?.count ?? 0) + 1,
                               previous.map { min($0.label, label) } ?? label)
            }
            if let km = estimatedDistanceKm(for: flight), (kilometers + km).isFinite {
                kilometers += km
                distanceCount += 1
            }
        }
        let most = routes.sorted {
            $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count
        }.first
        return Summary(journeyCount: flights.count, routeCount: routes.count,
                       routeJourneyCount: routeJourneyCount, estimatedKm: kilometers, distanceJourneyCount: distanceCount,
                       mostRecordedRoute: most?.value.label,
                       mostRecordedRouteCount: most?.value.count ?? 0)
    }

    private static func canonicalRouteLabel(_ flight: Flight) -> String {
        let from = endpointLabel(place: flight.departurePlace, code: flight.departureCode)
        let to = endpointLabel(place: flight.arrivalPlace, code: flight.arrivalCode)
        let stops = flight.stops?.map { nonempty($0.city) ?? $0.code } ?? []
        // Summary counts combine both directions; its label must say so.
        // The journal's primaryRoute remains directional for each journey.
        let forward = ([from] + stops + [to]).joined(separator: " ↔ ")
        let reverse = ([to] + stops.reversed() + [from]).joined(separator: " ↔ ")
        return min(forward, reverse)
    }

    private static func endpointLabel(place: String?, code: String?) -> String {
        nonempty(place) ?? nonempty(code) ?? "?"
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Airport identifiers are international ASCII tokens. Applying the
    /// device locale to one (IST → ıst in Turkish) makes lowercase queries
    /// disappear, so query and index always share this invariant fold.
    private static func folded(_ text: String) -> String {
        let locale = Locale(identifier: "en_US_POSIX")
        return text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
            .lowercased(with: locale)
    }

    private static func normalizedSearch(_ text: String) -> String {
        // These separators are presentation punctuation, not required route
        // terms. Normalize both sides, including hyphens within place names,
        // so pasting the directional row or a bidirectional summary works.
        let separators = CharacterSet(charactersIn: "→←↔⟶⟵⟷➝➜⇒⇐⇔<>-–—/|")
        return folded(text).components(separatedBy: separators).joined(separator: " ")
    }

    private static func searchTokens(_ text: String) -> [String] {
        normalizedSearch(text).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func encoded<S: Sequence>(_ parts: S) -> String where S.Element == String {
        parts.map { "\($0.utf8.count):\($0)" }.joined()
    }

    private static func newestFirst(_ lhs: Flight, _ rhs: Flight) -> Bool {
        let left = lhs.date.timeIntervalSinceReferenceDate
        let right = rhs.date.timeIntervalSinceReferenceDate
        let leftDate = left.isFinite ? left : -.greatestFiniteMagnitude
        let rightDate = right.isFinite ? right : -.greatestFiniteMagnitude
        return leftDate == rightDate ? lhs.id.uuidString < rhs.id.uuidString : leftDate > rightDate
    }

    private static func validWindow(start: Date, end: Date) -> Bool {
        start.timeIntervalSinceReferenceDate.isFinite && end.timeIntervalSinceReferenceDate.isFinite && start <= end
    }

    private static func civilYears(at date: Date, zoneIdentifier: String?) -> [Int] {
        var calendar = Calendar(identifier: .gregorian)
        if let zoneIdentifier, let zone = TimeZone(identifier: zoneIdentifier),
           let fixedOffset = TimeZone(secondsFromGMT: zone.secondsFromGMT(for: date)),
           zone.identifier != fixedOffset.identifier {
            calendar.timeZone = zone
            return [calendar.component(.year, from: date)]
        }
        // Imported stays use recognized GMT fixed-offset identifiers for
        // solar estimates. Their validity does not establish the political
        // zone or its civil year. Treat these, like unstamped zones, with
        // worldwide bounds instead of moving history on device travel.
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return [calendar.component(.year, from: date.addingTimeInterval(-12 * 3600)),
                calendar.component(.year, from: date.addingTimeInterval(14 * 3600))]
    }

    private static func dayText(_ date: Date, zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private static func civilDayNumber(_ date: Date, zone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return (components.year ?? 0) * 10_000 + (components.month ?? 0) * 100 + (components.day ?? 0)
    }

    private typealias Point = (latitude: Double, longitude: Double)

    private static func coordinate(_ latitude: Double?, _ longitude: Double?) -> Point? {
        guard let latitude, let longitude, latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        return (latitude, longitude)
    }

    private static func haversineKm(_ from: Point, _ to: Point) -> Double {
        let radians = Double.pi / 180
        let dLatitude = (to.latitude - from.latitude) * radians
        let dLongitude = (to.longitude - from.longitude) * radians
        let value = pow(sin(dLatitude / 2), 2)
            + cos(from.latitude * radians) * cos(to.latitude * radians) * pow(sin(dLongitude / 2), 2)
        return 6_371 * 2 * atan2(sqrt(max(0, min(value, 1))), sqrt(max(0, 1 - min(value, 1))))
    }
}
