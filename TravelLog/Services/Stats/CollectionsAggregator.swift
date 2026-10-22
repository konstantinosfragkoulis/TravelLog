//
//  CollectionsAggregator.swift
//  TravelLog
//
//  Pure reductions behind the Stats "Collections" feature:
//  airports visited, an inferred flight log, and the Places gazetteer.
//
//  Shape mirrors `StatsAggregator`: a `nonisolated` enum of pure static
//  reductions over already-fetched `Stay` rows, producing one `Sendable`
//  value. `StatsAggregator.aggregate` invokes `aggregate(rows:)`, over the
//  fields it copied once per row, on the same detached executor that
//  fetched the rows, so models never cross an isolation boundary. Airport
//  attribution is INJECTED (the
//  `HexVisibility.isVisible` predicate pattern) so unit tests pin the
//  grouping/tiering logic against fixture airports instead of the bundled
//  dataset.
//
//  # Semantic decisions
//
//  - **Airports**: a stay enters the collection only when `isAirport`,
//    with three admission guards:
//    routine stays never count; home-category stays count only when the
//    stay is ≥ `homeAtAirportExclusionKm` from the home centre (the home
//    RADIUS can swallow the home airport — ATH sits inside a 25 km Athens
//    home — but a stay AT the house must not become an airport visit for
//    users living inside the 3 km ring); set-foot visits need
//    ≥ `minSetFootDwellMinutes` of dwell (a motorway past an airbase can
//    cluster a brief stay inside the ring — Tanagra LGTG). Airports with
//    no scheduled service surface only with flown-through evidence. Tier
//    `flownThrough` marks airports that were an endpoint of an inferred
//    flight leg (those stays are dwell-exempt).
//  - **Flights**: a flight is kept on the stay carrying
//    `transitFromPreviousRaw == .flight` (that field means "how the user
//    travelled FROM the previous stay"), the first stay of a
//    `FlightJudge` journey; the flight runs from the journey's origin to
//    its destination (the brief stays between are waypoints: fixes in the
//    air, a photo on the way). The chain is walked at ANY gap —
//    TransitInferer's 7-day lookback is an INFERENCE rule, not a display
//    rule, and a `.flight` value is already vouched (wider gaps only arise
//    on review-queue-confirmed photo-era legs and partial imports, where
//    "the last place we saw you" is the honest departure). The review
//    queue offers the journeys `FlightJudge` finds flight-shaped, so the
//    log and the inferer never disagree on what a journey is.
//    Route codes are attributed only when the endpoint stay is itself
//    within the airport radius — we never guess a metropolitan airport
//    from a city-centre stay (London: LHR/LGW/STN would be a coin flip).
//    Durations are ESTIMATES from the standard block-time approximation
//    `hours = km/780 + 0.5` (`FlightJudge.blockHours`) — never presented
//    as measured fact.
//  - **Places**: destination stays only (transit never names a place —
//    the Stage-5 title discipline). Grouping key is the canonical
//    `metroName ?? islandName ?? locality` chain (same as
//    `Trip.recomputeSummary` / `StatsAggregator.mostVisitedCity`), keyed
//    with the ISO country so same-named places in different countries stay
//    distinct. Stays with none of the three names fall back to a 25 km
//    union-find cluster labelled by admin area / country (`.area` kind) so
//    every destination stay is represented.
//

import Foundation
import SwiftData
import CoreLocation

nonisolated enum CollectionsAggregator {

    // MARK: - Result types

    /// One airport in the "Airports visited" collection.
    nonisolated struct AirportEntry: Sendable, Equatable, Identifiable, Codable {
        let code: String
        let name: String?
        let city: String?
        let isoCountryCode: String?
        /// Mirrors `AirportRecord.svc` (nil → true). Entries without
        /// scheduled service are dropped unless flown through.
        let hasScheduledService: Bool
        var stayCount: Int
        var firstVisit: Date
        var lastVisit: Date
        /// True when this airport was an endpoint of an inferred flight leg
        /// (vs. merely set foot in — pickup, drop-off, spotting), or a stop
        /// the user added to a flight.
        var flownThrough: Bool
        /// Flights the user said connected here (`FlightStops`): visits no
        /// stay recorded. 0 in older snapshots.
        var connectionCount: Int = 0

        var id: String { code }

        /// Recorded stays and connections: what the list counts as visits.
        var visitCount: Int { stayCount + connectionCount }

        fileprivate enum CodingKeys: String, CodingKey {
            case code, name, city, isoCountryCode, hasScheduledService, stayCount,
                 firstVisit, lastVisit, flownThrough, connectionCount
        }
    }

    /// One inferred flight leg. `id` is the UUID of the stay holding the
    /// flight (the journey's first stay after its origin) — stable across
    /// recomputes, so SwiftUI list identity survives refreshes, and the key
    /// of the user's times, stops and dismissals.
    nonisolated struct FlightRecord: Sendable, Equatable, Identifiable, Codable {
        let id: UUID
        /// nil when the endpoint resolves to no airport, or is the house
        /// inside an airport ring (`hidingHomeAirportCodes`); the route then
        /// shows its place name.
        var departureCode: String?
        var arrivalCode: String?
        /// Place-name fallbacks (metro/island/locality chain) for endpoints
        /// that didn't resolve to an airport.
        let departurePlace: String?
        let arrivalPlace: String?
        let departureISO: String?
        let arrivalISO: String?
        /// The arrival (the journey's destination) stay's `startTime` — when
        /// the user was first seen landed.
        let date: Date
        let distanceKm: Double
        /// Block-time estimate (`km/780 + 0.5h`), NOT a measurement.
        let estimatedHours: Double
        /// nil when either endpoint's country is unknown.
        let isInternational: Bool?
        /// Solar time zones spanned (`|Δlongitude| / 15°`, antimeridian-safe).
        let timeZonesCrossed: Int
        /// True when the transit gap crosses 02:00 solar-local time at the
        /// departure longitude — the red-eye heuristic.
        let isOvernight: Bool
        /// Start of the window the flight must have occurred in (the
        /// previous stay's `endTime`); nil when the leg has no predecessor.
        /// `date` is the window's END — for photo-era legs the two can be
        /// days apart, so a single date would hide the uncertainty. The UI
        /// renders a day RANGE whenever the window spans calendar days.
        let departureWindowStart: Date?
        /// The endpoint stays' zones, so dates read as they did where the
        /// user was. nil in snapshots written before they were carried (and
        /// for unstamped stays): those dates read in the device zone.
        var departureTimeZoneIdentifier: String? = nil
        var arrivalTimeZoneIdentifier: String? = nil
        /// The arrival stay's trip, for flights only (candidates and older
        /// snapshots carry nil); a flight row without one opens its details.
        var tripID: UUID? = nil
        /// The arrival stay's physical row, so Not a Flight writes to it and
        /// never to a same-id twin. Not persisted, like
        /// `PossibleFlight.arrivalIdentifier`.
        var arrivalIdentifier: PersistentIdentifier? = nil

        // Context for the Flight Log's detail sheet (`withContext`), filled
        // after the leg was judged; nil in older snapshots.
        /// The airports' names, only for the codes the route shows.
        var departureAirportName: String? = nil
        var arrivalAirportName: String? = nil
        /// The points the detail map joins: the airport when its code shows,
        /// else the stay's centroid.
        var departureLatitude: Double? = nil
        var departureLongitude: Double? = nil
        var arrivalLatitude: Double? = nil
        var arrivalLongitude: Double? = nil
        /// When the user reached the departure place, and left the arrival
        /// place: the stays on either side of the window.
        var departureStayStart: Date? = nil
        var arrivalStayEnd: Date? = nil
        /// Whether either end is a home stay.
        var departureIsHome: Bool? = nil
        var arrivalIsHome: Bool? = nil
        /// The trips the endpoint stays belong to, for flights and candidates
        /// alike (`tripID` stays the row's navigation target).
        var departureTripID: UUID? = nil
        var arrivalTripID: UUID? = nil
        /// The user's own times (`FlightTimeOverrides`), set only while they
        /// fit the leg's window. They replace the window in the log's dates,
        /// the estimate in `flightHours` and the solar guess in
        /// `flewOvernight`.
        var userDeparture: Date? = nil
        var userArrival: Date? = nil
        /// The connections the user added (`FlightStops`), in order; nil for
        /// a nonstop. They split the journey into `legs`, which the totals
        /// count one by one; the journey's own fields (`distanceKm`, the
        /// window, international, time zones, overnight) stay end to end.
        var stops: [Stop]? = nil
        /// `FlightJudge`'s comparison of the journey: the window from the
        /// last fix at the origin, and what each way of travelling needs.
        /// The detail sheet's gap, speed verdict and evidence read it. nil
        /// in older snapshots, and when the data gives no window.
        var assessment: FlightJudge.Assessment? = nil

        /// A connecting airport, resolved from the bundled dataset.
        nonisolated struct Stop: Sendable, Equatable, Codable {
            let code: String
            let name: String?
            let city: String?
            let isoCountryCode: String?
            let latitude: Double
            let longitude: Double

            init(_ airport: AirportRecord) {
                code = airport.code
                name = airport.name
                city = airport.city
                isoCountryCode = airport.iso
                latitude = airport.lat
                longitude = airport.lon
            }
        }

        /// One hop between two points of the route.
        nonisolated struct Leg: Sendable, Equatable {
            let fromCode: String?
            let toCode: String?
            /// The code, else the place name.
            let from: String
            let to: String
            let distanceKm: Double

            var estimatedHours: Double { CollectionsAggregator.estimatedHours(distanceKm: distanceKm) }

            /// "FRA → LAX".
            var routeLabel: String {
                String(
                    localized: "collections.flight.route",
                    defaultValue: "\(from) → \(to)",
                    comment: "Flight route from departure airport or place to arrival airport or place."
                )
            }
        }

        private enum CodingKeys: String, CodingKey {
            case id, departureCode, arrivalCode, departurePlace, arrivalPlace,
                 departureISO, arrivalISO, date, distanceKm, estimatedHours,
                 isInternational, timeZonesCrossed, isOvernight, departureWindowStart,
                 departureTimeZoneIdentifier, arrivalTimeZoneIdentifier, tripID,
                 departureAirportName, arrivalAirportName,
                 departureLatitude, departureLongitude, arrivalLatitude, arrivalLongitude,
                 departureStayStart, arrivalStayEnd, departureIsHome, arrivalIsHome,
                 departureTripID, arrivalTripID, userDeparture, userArrival, stops, assessment
        }

        /// The user's times, when both are set.
        var userTimes: FlightTimeOverrides.Times? {
            guard let userDeparture, let userArrival else { return nil }
            return FlightTimeOverrides.Times(departure: userDeparture, arrival: userArrival)
        }

        /// Hours in the air: the user's times when set, else the block-time
        /// estimate over the legs.
        var flightHours: Double {
            userTimes.map { $0.duration / 3600 } ?? legsEstimatedHours
        }

        /// The legs flown: one for a nonstop (the journey itself), else one
        /// per hop through the stops, each the great-circle distance between
        /// its points. A hop whose end has no point (a record without its
        /// departure's context) takes an even share of what the measured
        /// hops leave of the journey's distance.
        var legs: [Leg] {
            let departure = departureCode ?? departurePlace ?? "?"
            let arrival = arrivalCode ?? arrivalPlace ?? "?"
            guard let stops, !stops.isEmpty else {
                return [Leg(fromCode: departureCode, toCode: arrivalCode,
                            from: departure, to: arrival, distanceKm: distanceKm)]
            }
            typealias Point = (code: String?, label: String, latitude: Double?, longitude: Double?)
            var points: [Point] = [(departureCode, departure, departureLatitude, departureLongitude)]
            for stop in stops {
                points.append((stop.code, stop.code, stop.latitude, stop.longitude))
            }
            points.append((arrivalCode, arrival, arrivalLatitude, arrivalLongitude))
            let hops = Array(zip(points, points.dropFirst()))
            let measured: [Double?] = hops.map { hop in
                guard let lat1 = hop.0.latitude, let lon1 = hop.0.longitude,
                      let lat2 = hop.1.latitude, let lon2 = hop.1.longitude else { return nil }
                return CollectionsAggregator.haversineKm(lat1: lat1, lon1: lon1, lat2: lat2, lon2: lon2)
            }
            let unmeasured = measured.count(where: { $0 == nil })
            let share = unmeasured == 0 ? 0
                : max(distanceKm - measured.compactMap { $0 }.reduce(0, +), 0) / Double(unmeasured)
            return zip(hops, measured).map { hop, distance in
                Leg(fromCode: hop.0.code, toCode: hop.1.code, from: hop.0.label, to: hop.1.label,
                    distanceKm: distance ?? share)
            }
        }

        /// The distance flown: the legs' sum (the journey's own distance for
        /// a nonstop).
        var flownKm: Double {
            guard stops?.isEmpty == false else { return distanceKm }
            return legs.reduce(0) { $0 + $1.distanceKm }
        }

        /// The block-time estimate over the legs.
        var legsEstimatedHours: Double {
            guard stops?.isEmpty == false else { return estimatedHours }
            return legs.reduce(0) { $0 + $1.estimatedHours }
        }

        /// The whole journey's estimate, its connections included: the legs
        /// plus `FlightStops.connectionHours` for each stop.
        var journeyEstimatedHours: Double {
            legsEstimatedHours + Double(stops?.count ?? 0) * FlightStops.connectionHours
        }

        /// The record wearing the stops `codes` name, in order, each once:
        /// at most `FlightStops.maximumStops` scheduled airports the
        /// dataset knows, neither end's own code. nil or no usable code
        /// leaves a nonstop.
        func applyingStops(
            _ codes: [String]?, resolve: (String) -> AirportRecord?
        ) -> FlightRecord {
            var record = self
            var stops: [Stop] = []
            for code in codes ?? [] where stops.count < FlightStops.maximumStops {
                guard code != departureCode, code != arrivalCode,
                      !stops.contains(where: { $0.code == code }),
                      let airport = resolve(code), airport.svc != false else { continue }
                stops.append(Stop(airport))
            }
            record.stops = stops.isEmpty ? nil : stops
            return record
        }

        /// The red-eye mark over the times the user set (certain times, so
        /// no window cap), else the derived `isOvernight`.
        var flewOvernight: Bool {
            guard let times = userTimes, let longitude = departureLongitude else { return isOvernight }
            return CollectionsAggregator.intervalCrossesSolarHour(
                start: times.departure, end: times.arrival, longitude: longitude, hour: 2)
        }

        /// The record wearing `times` when they fit its window, else without
        /// any (`FlightTimeOverrides.fits`).
        func applyingUserTimes(_ times: FlightTimeOverrides.Times?) -> FlightRecord {
            var record = self
            if let times, FlightTimeOverrides.fits(times, windowStart: departureWindowStart, windowEnd: date) {
                record.userDeparture = times.departure
                record.userArrival = times.arrival
            } else {
                record.userDeparture = nil
                record.userArrival = nil
            }
            return record
        }

        /// "ATH → AMS", or "ATH → FRA → LAX" through the stops, falling
        /// back to place names for unresolved ends.
        var routeLabel: String {
            Self.route(departureCode ?? departurePlace ?? "?",
                       through: stops?.map(\.code) ?? [],
                       to: arrivalCode ?? arrivalPlace ?? "?")
        }

        /// "Syros → Athens" (stops by their cities) under the codes line:
        /// both places known, and not a repeat of `routeLabel`.
        var placeRouteLabel: String? {
            guard let dep = departurePlace, let arr = arrivalPlace else { return nil }
            let label = Self.route(dep, through: stops?.map { $0.city ?? $0.code } ?? [], to: arr)
            return label == routeLabel ? nil : label
        }

        /// The places in order, joined by arrows.
        static func route(_ from: String, through stops: [String], to: String) -> String {
            switch stops.count {
            case 0:
                String(
                    localized: "collections.flight.route",
                    defaultValue: "\(from) → \(to)",
                    comment: "Flight route from departure airport or place to arrival airport or place."
                )
            case 1:
                String(
                    localized: "collections.flight.route.one-stop",
                    defaultValue: "\(from) → \(stops[0]) → \(to)",
                    comment: "Flight route through one connection: departure airport or place, the connecting airport or city, then the arrival airport or place."
                )
            default:
                String(
                    localized: "collections.flight.route.two-stops",
                    defaultValue: "\(from) → \(stops[0]) → \(stops[1]) → \(to)",
                    comment: "Flight route through two connections: departure airport or place, the two connecting airports or cities in order, then the arrival airport or place."
                )
            }
        }
    }

    /// Why a journey is offered as a possible flight: `FlightJudge.Reason`.
    /// The raw values of the four older evidence tiers stay, so candidates
    /// cached in a stats snapshot still decode, each as the reason that
    /// replaced it.
    nonisolated enum CandidateEvidence: String, Sendable, Equatable, Codable {
        case seenInAir
        case tooFastForSurface = "fastLeg"
        case airportToAirport = "bothAirports"
        case acrossWater = "islandHop"
        case tooFarOverland
        case longGap = "countryJump"

        init(_ reason: FlightJudge.Reason) {
            switch reason {
            case .seenInAir: self = .seenInAir
            case .tooFastForSurface: self = .tooFastForSurface
            case .airportToAirport: self = .airportToAirport
            case .acrossWater: self = .acrossWater
            case .tooFarOverland: self = .tooFarOverland
            case .longGap: self = .longGap
            }
        }

        var displayText: String {
            switch self {
            case .seenInAir:
                String(localized: "collections.flight-evidence.seen-in-air", defaultValue: "Seen in the air", comment: "Reason a route may be a flight: two locations on the way were reached faster than anything on the ground.")
            case .tooFastForSurface:
                String(localized: "collections.flight-evidence.speed", defaultValue: "Too fast for ground travel", comment: "Reason a route may be a flight.")
            case .airportToAirport:
                String(localized: "collections.flight-evidence.airports", defaultValue: "Airport to airport", comment: "Reason a route may be a flight.")
            case .acrossWater:
                String(localized: "collections.flight-evidence.across-water", defaultValue: "Across water, faster than a ferry", comment: "Reason a route may be a flight: between islands, or an island and the mainland, faster than a ferry sails.")
            case .tooFarOverland:
                String(localized: "collections.flight-evidence.too-far-overland", defaultValue: "Too far to travel by land in this time", comment: "Reason a route may be a flight: farther than a car or train usually gets in the time between the two places.")
            case .longGap:
                String(localized: "collections.flight-evidence.long-gap", defaultValue: "Long gap, may have flown", comment: "Reason a route may be a flight: a long way with a long time and no location in between.")
            }
        }
    }

    /// A review-queue entry: a journey of `.unknown` legs `FlightJudge`
    /// finds flight-shaped, kept on its first stay. NEVER written by the
    /// Flight Log — the user confirms (→ `.flight`, terminal) or dismisses
    /// (persisted via `FlightCandidateDismissals`).
    nonisolated struct PossibleFlight: Sendable, Equatable, Identifiable, Codable {
        var record: FlightRecord
        let evidenceRaw: String
        /// The window the data leaves, from the last fix at the origin to the
        /// first at the destination, for the evidence line.
        let gapHours: Double
        /// The physical row of the stay the flight goes on, so Confirm writes
        /// to it and never to a same-id twin. Not persisted: a candidate read back from the
        /// stats snapshot has none until the next aggregate replaces it.
        var arrivalIdentifier: PersistentIdentifier? = nil
        /// The leg into the stay the flight goes on (from the journey's
        /// origin), when the journey runs on past it: what Confirm stores as
        /// that stay's leg distance, so trip totals count each leg once. nil
        /// when the journey is that one leg (Confirm stores the distance
        /// shown) and in older snapshots.
        var legKm: Double? = nil

        private enum CodingKeys: String, CodingKey {
            case record, evidenceRaw, gapHours, legKm
        }

        var id: UUID { record.id }
        var evidence: CandidateEvidence? { CandidateEvidence(rawValue: evidenceRaw) }

        /// The evidence line's reason.
        var evidenceDisplayText: String? { evidence?.displayText }
    }

    /// Lifetime flight totals for the flight-log header.
    nonisolated struct FlightStats: Sendable, Equatable, Codable {
        var totalFlights = 0
        var totalKm: Double = 0
        var totalEstimatedHours: Double = 0
        var internationalCount = 0
        var overnightCount = 0
        /// Σ |Δtz| across all legs — the "jetlag ledger".
        var timeZonesCrossedTotal = 0
        var longestKm: Double = 0
        var longestRouteLabel: String?
        var mostFlownRouteLabel: String?
        var mostFlownRouteCount = 0
    }

    /// How a place earned its top-level identity.
    nonisolated enum PlaceKind: String, Sendable, Comparable, Codable {
        case metro      // FUA membership: "Athens" absorbing its suburbs
        case island     // island grouping: "Syros" absorbing its main settlement
        case locality   // standalone GeoNames place — towns, villages
        case area       // geometric fallback cluster for un-geocoded stays

        /// metro > island > locality > area, for keeping the strongest kind
        /// when stays of mixed geocode quality land in one entry.
        private var rank: Int {
            switch self {
            case .metro: 3
            case .island: 2
            case .locality: 1
            case .area: 0
            }
        }
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
    }

    /// One row of the Places gazetteer.
    nonisolated struct PlaceEntry: Sendable, Equatable, Identifiable, Codable {
        let id: String
        let name: String
        let isoCountryCode: String?
        let country: String?
        var kind: PlaceKind
        /// Distinct trips with at least one destination stay here (the
        /// `mostVisitedCity` unit: a week on Syros with many stays is ONE visit).
        var tripCount: Int
        var stayCount: Int
        /// Distinct civil days (in each stay's own zone, UTC when unstamped)
        /// covered by this place's stays.
        var dayCount: Int
        var firstVisit: Date
        var lastVisit: Date
        /// Constituent locality names ≠ the place name (suburbs grouped under
        /// Athens). Deduplicated, insertion-ordered.
        var localities: [String]
    }

    /// Everything the Collections UI shows, as one Sendable value.
    nonisolated struct Collections: Sendable, Equatable, Codable {
        var airports: [AirportEntry] = []      // alphabetical by code
        var flights: [FlightRecord] = []       // newest first
        var flightStats = FlightStats()
        /// Review queue — flight-shaped `.unknown` legs, newest first,
        /// dismissed IDs already excluded.
        var possibleFlights: [PossibleFlight] = []
        var places: [PlaceEntry] = []          // most-visited first
    }

    /// Injectable airport attribution — production default is the bundled
    /// dataset via `AirportDetector.nearestAirport` (3 km, the same radius
    /// that stamps `Stay.isAirport`).
    typealias AirportResolver = (CLLocationCoordinate2D) -> AirportRecord?
    /// A flight end's airport, given the end and the flight's other end.
    typealias EndAirportResolver = (_ end: Endpoint, _ other: Endpoint?) -> AirportRecord?

    /// The production resolver for the airport serving a place: the
    /// nearest with scheduled service within `FlightJudge.servingRadiusKm`.
    static func bundledServingAirport(_ coordinate: CLLocationCoordinate2D) -> AirportRecord? {
        AirportDetector.shared.nearestAirport(
            coordinate, radiusMeters: FlightJudge.servingRadiusKm * 1000, scheduledOnly: true)
    }

    /// Injectable candidates for the airport a place likely flew from.
    typealias AirportListResolver = (CLLocationCoordinate2D) -> [AirportRecord]

    /// The production candidates: every scheduled airport out to
    /// `AccessAirport.majorReachKm` (with room for the detector's
    /// approximate distance; `AccessAirport.choose` measures exactly).
    static func bundledAccessAirports(_ coordinate: CLLocationCoordinate2D) -> [AirportRecord] {
        AirportDetector.shared.airports(
            near: coordinate, radiusMeters: (AccessAirport.majorReachKm + 5) * 1000, scheduledOnly: true)
    }

    // MARK: - Row values

    /// A flight-leg end, copied once from a stay. Its fields are exactly
    /// `StatsAggregator.predecessorStayProperties`, so a predecessor-only row
    /// never faults in a field its fetch left out.
    nonisolated struct Endpoint {
        let id: UUID
        let startTime: Date
        let endTime: Date
        let centroidLatitude: Double
        let centroidLongitude: Double
        let isoCountryCode: String?
        let metroName: String?
        let islandName: String?
        let locality: String?
        let administrativeArea: String?
        let country: String?
        let isAirport: Bool
        let timeZoneIdentifier: String?
        /// An airport-ring home stay at the house (the Airports list's
        /// `homeAtAirportExclusionKm` rule): never an airport visit, and
        /// never an airport code on a flight leg.
        let isHomeAtAirport: Bool
        /// Fixes clustered into the stay, and whether a photo placed it:
        /// what `FlightJudge` reads of how sure the stay's place and times
        /// are.
        let pingCount: Int
        let isPhoto: Bool

        init(_ stay: Stay) {
            self.init(stay, categoryRaw: stay.categoryRaw)
        }

        /// `categoryRaw` already read by the caller, so it is read once.
        init(_ stay: Stay, categoryRaw: String) {
            id = stay.id
            startTime = stay.startTime
            endTime = stay.endTime
            centroidLatitude = stay.centroidLatitude
            centroidLongitude = stay.centroidLongitude
            isoCountryCode = stay.isoCountryCode
            metroName = stay.metroName
            islandName = stay.islandName
            locality = stay.locality
            administrativeArea = stay.administrativeArea
            country = stay.country
            isAirport = stay.isAirport
            timeZoneIdentifier = stay.timeZoneIdentifier
            isHomeAtAirport = isAirport && categoryRaw == StayCategory.home.rawValue
                && stay.distanceFromHomeKm < homeAtAirportExclusionKm
            pingCount = stay.pingCount
            isPhoto = stay.sourceRaw == DataSource.photoImport.rawValue
        }
    }

    /// The fields Collections and Stats read from one fetched stay, copied
    /// once: every model getter pays SwiftData's key-path machinery, and the
    /// leg walk alone revisits a row many times. `StatsAggregator` builds
    /// these right after its fetch and shares them with `aggregate(rows:)`.
    /// Fields a single pass reads (airport dwell, the two distances,
    /// weather) stay on `model`.
    nonisolated struct StayRow {
        let model: Stay
        let endpoint: Endpoint
        let categoryRaw: String
        let transitFromPreviousRaw: String?
        let h3IndexRes6: String
        let avgTemperatureC: Double?
        /// Destination stays only (nil for others) unless `anyCategory`:
        /// trip membership and the stay's zone.
        let tripID: UUID?
        let timeZoneIdentifier: String?
        /// Home stays only (nil for others): who recorded the stay home.
        let temporaryHomeID: UUID?

        /// `anyCategory` reads the destination fields whatever the category,
        /// for test seams that take arbitrary stays.
        init(_ stay: Stay, anyCategory: Bool = false) {
            let category = stay.categoryRaw
            model = stay
            endpoint = Endpoint(stay, categoryRaw: category)
            categoryRaw = category
            transitFromPreviousRaw = stay.transitFromPreviousRaw
            h3IndexRes6 = stay.h3IndexRes6
            avgTemperatureC = stay.avgTemperatureC
            if anyCategory || category == StayCategory.destination.rawValue {
                tripID = stay.trip?.id
                timeZoneIdentifier = endpoint.timeZoneIdentifier
            } else {
                tripID = nil
                timeZoneIdentifier = nil
            }
            temporaryHomeID = category == StayCategory.home.rawValue ? stay.temporaryHomeID : nil
        }

        var id: UUID { endpoint.id }
        var startTime: Date { endpoint.startTime }
        var endTime: Date { endpoint.endTime }
        var centroidLatitude: Double { endpoint.centroidLatitude }
        var centroidLongitude: Double { endpoint.centroidLongitude }
        var isoCountryCode: String? { endpoint.isoCountryCode }
        var metroName: String? { endpoint.metroName }
        var islandName: String? { endpoint.islandName }
        var locality: String? { endpoint.locality }
        var administrativeArea: String? { endpoint.administrativeArea }
        var country: String? { endpoint.country }
        var isAirport: Bool { endpoint.isAirport }
        /// `Stay.placeGroupName` over the copied names.
        var placeGroupName: String? { metroName ?? islandName ?? locality }
    }

    /// Memo key for per-aggregation airport-resolution caching.
    /// Exact-equality on the raw coordinate doubles is correct here: entries
    /// come from stable stored `Stay.centroidLatitude/Longitude` values, so
    /// repeat lookups for the same stay are bit-identical.
    private struct AirportMemoKey: Hashable {
        let lat: Double
        let lon: Double
    }

    // MARK: - Tunables

    /// Widest endpoint window that may still claim an overnight flight.
    /// `intervalCrossesSolarHour` is vacuously true for any window ≥ 24 h
    /// (it contains every solar hour), so a photo-era leg whose fixes sit
    /// days apart would otherwise always read "overnight" — a fabricated
    /// red-eye. Live-inferred flights can't hit this (the speed gate keeps
    /// their fix-to-fix gap far below a day); legs with wider windows just
    /// don't make the claim.
    private static let overnightMaxWindowSeconds: TimeInterval = 24 * 60 * 60

    /// The block-time estimate for a flight this far: the judge's usual
    /// flight (`FlightJudge.blockHours`, 780 km/h plus half an hour for
    /// taxi and runway; good to about 15%).
    static func estimatedHours(distanceKm: Double) -> Double {
        FlightJudge.blockHours(distanceKm: distanceKm)
    }

    /// Same 25 km metro threshold as `Stay.deduplicatedCityCount` for the
    /// un-geocoded `.area` fallback clusters.
    static let areaClusterThresholdKm: Double = 25   // internal: oracle-test reference

    /// Home-category stays are excluded from airport visits only when the
    /// stay is close to the home centre. A home radius can contain an airport,
    /// so category alone would also exclude genuine departure dwells. Use the
    /// actual distance from home to distinguish those from stays at the house.
    private static let homeAtAirportExclusionKm: Double = 5

    /// Minimum dwell for a set-foot airport visit. A motorway past an
    /// airbase can cluster a brief stay inside the 3 km ring without an
    /// airport visit. Flight-endpoint stays are exempt: a short SLC dwell
    /// at the arrival airport is still a flown-through visit.
    private static let minSetFootDwellMinutes = 15

    /// Defensive cap on per-stay day iteration (a stay's `endTime` can only
    /// extend, but a corrupt multi-year row must not spin the UTC-day walk).
    private static let maxDaysPerStay = 1000

    /// Day labels of an unstamped stay read in UTC.
    private static let utcZone = TimeZone(secondsFromGMT: 0)!

    /// Island-adoption radius for port stays whose offshore centroids miss
    /// the island polygon. Kept tight to cover a port and its hillside village
    /// without grouping nearby landmasses across a wider strait.
    static let islandAdoptionRadiusKm: Double = 5   // internal: oracle-test reference

    // MARK: - Entry point

    /// Reduce already-fetched stays into the three collections. `stays` may
    /// arrive in any order and any category mix; home/routine rows are
    /// needed (they are flight-leg predecessors) even though they never
    /// become airport or place entries themselves.
    static func aggregate(
        stays: [Stay], predecessorOnlyStays: [Stay] = [],
        nearestAirport: AirportResolver = {
            AirportDetector.shared.nearestAirport($0, radiusMeters: 3000)
        },
        servingAirport: AirportResolver = bundledServingAirport,
        accessAirports: AirportListResolver = bundledAccessAirports,
        dismissedCandidates: Set<UUID> = FlightCandidateDismissals.all()
    ) -> Collections {
        aggregate(stays: stays, predecessorOnlyStays: predecessorOnlyStays,
                  nearestAirport: nearestAirport, servingAirport: servingAirport,
                  accessAirports: accessAirports,
                  dismissedCandidates: dismissedCandidates,
                  checkCancellation: {})
    }

    static func aggregate(
        stays: [Stay],
        predecessorOnlyStays: [Stay] = [],
        nearestAirport: AirportResolver = {
            AirportDetector.shared.nearestAirport($0, radiusMeters: 3000)
        },
        servingAirport: AirportResolver = bundledServingAirport,
        accessAirports: AirportListResolver = bundledAccessAirports,
        dismissedCandidates: Set<UUID> = FlightCandidateDismissals.all(),
        checkCancellation: () throws -> Void
    ) rethrows -> Collections {
        // Copies check cancellation per row, as the model-read passes did.
        try checkCancellation()
        return try aggregate(
            rows: stays.map {
                try checkCancellation()
                return StayRow($0)
            },
            predecessorOnly: predecessorOnlyStays.map {
                try checkCancellation()
                return Endpoint($0)
            },
            nearestAirport: nearestAirport, servingAirport: servingAirport,
            accessAirports: accessAirports,
            dismissedCandidates: dismissedCandidates,
            checkCancellation: checkCancellation)
    }

    /// The reduction itself, over fields copied once per stay.
    static func aggregate(
        rows: [StayRow],
        predecessorOnly: [Endpoint],
        nearestAirport: AirportResolver = {
            AirportDetector.shared.nearestAirport($0, radiusMeters: 3000)
        },
        servingAirport: AirportResolver = bundledServingAirport,
        accessAirports: AirportListResolver = bundledAccessAirports,
        dismissedCandidates: Set<UUID> = FlightCandidateDismissals.all(),
        flightTimes: [UUID: FlightTimeOverrides.Times] = FlightTimeOverrides.all(),
        flightStops: [UUID: [String]] = FlightStops.all(),
        airportByCode: (String) -> AirportRecord? = { AirportDetector.shared.airport(code: $0) },
        checkCancellation: () throws -> Void
    ) rethrows -> Collections {
        try checkCancellation()
        // Deterministic base order: (startTime, id) — the same tiebreak
        // discipline as every other aggregate in this codebase.
        let byStart = rows.map { (row: $0, start: $0.startTime, id: $0.id.uuidString) }
            .sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.id < $1.id
            }
            .map { $0.row }

        // Per-aggregation memo: each stay's centroid is resolved up to three
        // times (as a leg's arrival, as the next leg's predecessor, and again
        // in airportEntries) and every miss is a full linear scan of the
        // airport table. Centroids are stable stored properties, so caching
        // by coordinate is exact. Single-threaded closure — the whole
        // aggregate runs inside one detached task.
        var airportMemo: [AirportMemoKey: AirportRecord?] = [:]
        let memoizedResolver: AirportResolver = { coordinate in
            let key = AirportMemoKey(lat: coordinate.latitude, lon: coordinate.longitude)
            if let cached = airportMemo[key] { return cached }
            let resolved = nearestAirport(coordinate)
            airportMemo[key] = resolved
            return resolved
        }

        var servingMemo: [AirportMemoKey: AirportRecord?] = [:]
        let memoizedServing: AirportResolver = { coordinate in
            let key = AirportMemoKey(lat: coordinate.latitude, lon: coordinate.longitude)
            if let cached = servingMemo[key] { return cached }
            let resolved = servingAirport(coordinate)
            servingMemo[key] = resolved
            return resolved
        }

        var accessMemo: [AirportMemoKey: [AirportRecord]] = [:]
        let memoizedAccess: AirportListResolver = { coordinate in
            let key = AirportMemoKey(lat: coordinate.latitude, lon: coordinate.longitude)
            if let cached = accessMemo[key] { return cached }
            let resolved = accessAirports(coordinate)
            accessMemo[key] = resolved
            return resolved
        }

        var result = Collections()
        // Flights first: their endpoint stay IDs exempt brief arrival/
        // departure dwells from the set-foot minimum.
        let (flights, candidates, endpointStayIDs, recordlessEndpointCodes) = try flightRecords(
            byStart: byStart,
            predecessorOnly: predecessorOnly,
            nearestAirport: memoizedResolver,
            servingAirport: memoizedServing,
            accessAirports: memoizedAccess,
            dismissedCandidates: dismissedCandidates,
            checkCancellation: checkCancellation
        )
        var airportVisits = try airportEntries(
            byStart: byStart,
            flightEndpointStayIDs: endpointStayIDs,
            nearestAirport: memoizedResolver,
            checkCancellation: checkCancellation
        )

        // The user's own stops and times, where they set them, before the
        // log, its totals and the airports read them.
        let finishedFlights = flights.map {
            $0.applyingStops(flightStops[$0.id], resolve: airportByCode)
                .applyingUserTimes(flightTimes[$0.id])
        }

        // Tier pass: an airport that appears as a flight endpoint is
        // flown-through. Codes without a visit entry are deliberately NOT
        // materialized, and a stay at the user's house names no code at
        // all — being near an airport at home is not a visit.
        for flight in finishedFlights {
            try checkCancellation()
            if let code = flight.departureCode { airportVisits[code]?.flownThrough = true }
            if let code = flight.arrivalCode { airportVisits[code]?.flownThrough = true }
            // A stop the user named is the exception: the connection is
            // the visit, on the day the log shows for the flight.
            let day = flight.userArrival ?? flight.date
            for stop in flight.stops ?? [] {
                if var entry = airportVisits[stop.code] {
                    entry.flownThrough = true
                    entry.connectionCount += 1
                    entry.firstVisit = min(entry.firstVisit, day)
                    entry.lastVisit = max(entry.lastVisit, day)
                    airportVisits[stop.code] = entry
                } else {
                    airportVisits[stop.code] = AirportEntry(
                        code: stop.code, name: stop.name, city: stop.city,
                        isoCountryCode: stop.isoCountryCode, hasScheduledService: true,
                        stayCount: 0, firstVisit: day, lastVisit: day,
                        flownThrough: true, connectionCount: 1)
                }
            }
        }
        // Geometry-less terminal flights: their endpoints
        // kept the dwell exemption, so their resolvable airports must carry
        // the flown-through tier too.
        for code in recordlessEndpointCodes {
            try checkCancellation()
            airportVisits[code]?.flownThrough = true
        }

        // Non-scheduled fields (military/GA — Tanagra LGTG) need flight
        // evidence to surface; scheduled airports keep every dwell visit.
        airportVisits = airportVisits.filter {
            $0.value.hasScheduledService || $0.value.flownThrough
        }

        result.airports = airportVisits.values.sorted { $0.code < $1.code }
        result.flights = finishedFlights.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id.uuidString < $1.id.uuidString
        }
        result.flightStats = flightStats(from: finishedFlights)
        result.possibleFlights = candidates
            .filter { !dismissedCandidates.contains($0.id) }
            .sorted {
                if $0.record.date != $1.record.date { return $0.record.date > $1.record.date }
                return $0.id.uuidString < $1.id.uuidString
            }
        try checkCancellation()
        result.places = try placeEntries(byStart: byStart, checkCancellation: checkCancellation)
        try checkCancellation()
        return result
    }

    // MARK: - Airports

    private static func airportEntries(
        byStart: [StayRow],
        flightEndpointStayIDs: Set<UUID>,
        nearestAirport: AirportResolver,
        checkCancellation: () throws -> Void
    ) rethrows -> [String: AirportEntry] {
        var entries: [String: AirportEntry] = [:]
        let routineRaw = StayCategory.routine.rawValue

        for stay in byStart where stay.isAirport {
            try checkCancellation()
            // Routine places near an airport (a gym inside the ring) are
            // never airport visits.
            if stay.categoryRaw == routineRaw { continue }
            // Home-category stays are excluded only when actually AT home —
            // a home RADIUS can swallow the home airport (ATH in a 25 km
            // Athens home), and those departure dwells are real visits.
            if stay.endpoint.isHomeAtAirport { continue }
            // Drive-by guard: brief clustered stays inside the ring (a
            // motorway past an airbase) need flight evidence to count.
            let isFlightEndpoint = flightEndpointStayIDs.contains(stay.id)
            if !isFlightEndpoint, stay.model.durationMinutes < minSetFootDwellMinutes { continue }
            guard let record = nearestAirport(
                CLLocationCoordinate2D(latitude: stay.centroidLatitude,
                                       longitude: stay.centroidLongitude)
            ) else { continue }

            if var entry = entries[record.code] {
                entry.stayCount += 1
                entry.firstVisit = min(entry.firstVisit, stay.startTime)
                entry.lastVisit = max(entry.lastVisit, stay.endTime)
                entries[record.code] = entry
            } else {
                entries[record.code] = AirportEntry(
                    code: record.code,
                    name: record.name,
                    city: record.city,
                    isoCountryCode: record.iso,
                    hasScheduledService: record.svc ?? true,
                    stayCount: 1,
                    firstVisit: stay.startTime,
                    lastVisit: stay.endTime,
                    flownThrough: false
                )
            }
        }
        return entries
    }

    // MARK: - Flights

    /// One stay of the flight walk: a row, or a backlog predecessor
    /// (`predecessorOnly`), which joins only the walk.
    private struct WalkStay {
        let endpoint: Endpoint
        let row: StayRow?
    }

    /// What `FlightJudge` reads from a walk stay. A backlog predecessor has
    /// no leg yet.
    private static func judgeStay(_ stay: WalkStay) -> FlightJudge.Stay {
        let endpoint = stay.endpoint
        return FlightJudge.Stay(
            id: endpoint.id, start: endpoint.startTime, end: endpoint.endTime,
            latitude: endpoint.centroidLatitude, longitude: endpoint.centroidLongitude,
            isAirport: endpoint.isAirport, islandName: endpoint.islandName,
            pingCount: endpoint.pingCount, isPhoto: endpoint.isPhoto,
            mode: stay.row.map { FlightJudge.Mode(raw: $0.transitFromPreviousRaw) } ?? .pending)
    }

    /// Returns the flights (every stay holding `.flight`), the review
    /// queue's candidates, and the IDs of every stay that served as a REAL
    /// flight endpoint (the stay holding the flight and its journey's ends):
    /// those stays are exempt from the set-foot dwell minimum in
    /// `airportEntries`. Candidates never grant exemptions or materialize
    /// airports: they are suggestions until the user confirms.
    ///
    /// Both read `FlightJudge`'s journeys over every stay, the backlog
    /// predecessors included: `TransitInferer` reads the same timeline, so
    /// during a classification backlog the departure is still the true
    /// chronological one. A flight runs from its journey's origin to its
    /// destination (with more than one flight in a journey, each runs to the
    /// stay before the next); a candidate is a journey none of whose stays
    /// holds a decision, judged worth asking about, on its first stay.
    private static func flightRecords(
        byStart: [StayRow],
        predecessorOnly: [Endpoint],
        nearestAirport: AirportResolver,
        servingAirport: AirportResolver,
        accessAirports: AirportListResolver,
        dismissedCandidates: Set<UUID>,
        checkCancellation: () throws -> Void
    ) rethrows -> (flights: [FlightRecord], candidates: [PossibleFlight], endpointStayIDs: Set<UUID>, recordlessEndpointCodes: Set<String>) {
        let walk = byStart.map { WalkStay(endpoint: $0.endpoint, row: $0) }
            + predecessorOnly.map { WalkStay(endpoint: $0, row: nil) }
        var input: [FlightJudge.Stay] = []
        input.reserveCapacity(walk.count)
        for stay in walk {
            try checkCancellation()
            input.append(judgeStay(stay))
        }
        let timeline = FlightJudge.Timeline(input)
        let ordered = timeline.inputIndex.map { walk[$0] }
        // The judge asks about stays' own centroids only: resolved up front,
        // so its lookups hold values rather than the resolvers.
        var ringAirports: [AirportMemoKey: FlightJudge.Airport] = [:]
        var servingAirports: [AirportMemoKey: FlightJudge.Airport] = [:]
        var resolved: Set<AirportMemoKey> = []
        for stay in timeline.stays {
            try checkCancellation()
            let key = AirportMemoKey(lat: stay.latitude, lon: stay.longitude)
            guard resolved.insert(key).inserted else { continue }
            let coordinate = CLLocationCoordinate2D(latitude: stay.latitude, longitude: stay.longitude)
            ringAirports[key] = nearestAirport(coordinate).map(FlightJudge.Airport.init)
            servingAirports[key] = servingAirport(coordinate).map(FlightJudge.Airport.init)
        }
        let rings = ringAirports, serving = servingAirports
        let airports = FlightJudge.Airports(
            at: { rings[AirportMemoKey(lat: $0, lon: $1)] },
            serving: { serving[AirportMemoKey(lat: $0, lon: $1)] })

        // An end outside every airport's ring shows the airport that likely
        // served it (`AccessAirport`): the nearest the user has been at (a
        // stay in its ring) within `FlightJudge.servingRadiusKm`, else the
        // cheapest drive plus tier penalty for a flight that far. The judge's
        // timing keeps the nearest: its fastest flight is a bound, and a
        // farther airport would raise it past real flights.
        var knownAirports: [String: AirportRecord] = [:]
        for stay in walk where stay.endpoint.isAirport && !stay.endpoint.isHomeAtAirport {
            try checkCancellation()
            if stay.row?.categoryRaw == StayCategory.routine.rawValue { continue }
            guard let record = nearestAirport(CLLocationCoordinate2D(
                latitude: stay.endpoint.centroidLatitude, longitude: stay.endpoint.centroidLongitude)),
                record.svc != false else { continue }
            knownAirports[record.code] = record
        }
        let known = knownAirports.values.sorted { $0.code < $1.code }
        // Far: another country, or `AccessAirport.farFlightKm` and more.
        func isFar(_ end: Endpoint, _ other: Endpoint?) -> Bool {
            guard let other else { return false }
            if let here = end.isoCountryCode?.uppercased(), let there = other.isoCountryCode?.uppercased(),
               !here.isEmpty, !there.isEmpty, here != there { return true }
            return haversineKm(lat1: end.centroidLatitude, lon1: end.centroidLongitude,
                               lat2: other.centroidLatitude, lon2: other.centroidLongitude)
                >= AccessAirport.farFlightKm
        }
        func likelyAirport(_ end: Endpoint, toward other: Endpoint?) -> AirportRecord? {
            let coordinate = CLLocationCoordinate2D(latitude: end.centroidLatitude,
                                                    longitude: end.centroidLongitude)
            // No scheduled airport serves the place: none competes. On an
            // island the nearest stays: an airport across the water is a
            // ferry away, not a drive.
            var candidates: [AirportRecord] = []
            if let serving = servingAirport(coordinate) {
                candidates = [serving] + ((end.islandName ?? "").isEmpty ? accessAirports(coordinate) : [])
            }
            return AccessAirport.choose(latitude: coordinate.latitude, longitude: coordinate.longitude,
                                        candidates: candidates, visited: known, far: isFar(end, other))
        }
        func endAirport(_ end: Endpoint, toward other: Endpoint?) -> AirportRecord? {
            nearestAirport(CLLocationCoordinate2D(latitude: end.centroidLatitude,
                                                  longitude: end.centroidLongitude))
                ?? likelyAirport(end, toward: other)
        }

        var records: [FlightRecord] = []
        var candidates: [PossibleFlight] = []
        var endpointStayIDs: Set<UUID> = []
        var recordlessEndpointCodes: Set<String> = []

        for index in ordered.indices {
            try checkCancellation()
            guard let row = ordered[index].row, timeline.stays[index].mode == .flight else { continue }
            let ends = flightEnds(of: index, in: timeline)
            let departure = ends.departure.map { ordered[$0] }
            let arrival = ordered[ends.arrival]
            endpointStayIDs.insert(row.id)
            if let departure { endpointStayIDs.insert(departure.endpoint.id) }
            endpointStayIDs.insert(arrival.endpoint.id)
            // The stored distance measured the leg into this stay: it holds
            // for the record only while the flight is that leg.
            let storedDistance = ends.departure == timeline.previous[index] && ends.arrival == index
                || ends.departure == nil ? row.model.distanceFromPreviousKm : nil
            if var record = legRecord(stay: row, previous: departure?.endpoint,
                                      lastSeen: ends.departure.map(timeline.lastSeen), arrival: arrival.endpoint,
                                      nearestAirport: nearestAirport, endAirport: endAirport,
                                      storedDistance: storedDistance) {
                record = hidingHomeAirportCodes(record, previous: departure?.endpoint, arrival: arrival.endpoint)
                record.tripID = row.model.trip?.id ?? arrival.row?.model.trip?.id
                record.arrivalIdentifier = row.model.persistentModelID
                record.assessment = ends.journey.flatMap {
                    FlightJudge.assess($0, in: timeline, airports: airports)
                }
                record = withContext(record, stay: row, previous: departure, arrival: arrival,
                                     endAirport: endAirport)
                records.append(record)
            } else {
                // Geometry-less terminal flight (partial JSON restore /
                // missing predecessor): the endpoints keep their dwell
                // exemption — the persisted evidence vouches a flight —
                // so any endpoint that itself resolves to an airport
                // must also read flown-through, or the exemption and
                // the tier contradict each other.
                for end in [row.endpoint, arrival.endpoint] + (departure.map { [$0.endpoint] } ?? []) {
                    if let code = nearestAirport(CLLocationCoordinate2D(
                        latitude: end.centroidLatitude, longitude: end.centroidLongitude))?.code {
                        recordlessEndpointCodes.insert(code)
                    }
                }
            }
        }

        // Candidates: journeys whose every leg is `.unknown` (or a legacy
        // ground mode, which only impossible speed re-opens), none of whose
        // stays the user dismissed. The judge's numbers ride along for the
        // detail sheet. A journey the inferer would record (it was judged
        // under older rules or data) is offered too, until Detect Flights
        // re-judges it.
        var offered: Set<Int> = []
        for journey in timeline.journeys() {
            try checkCancellation()
            guard offered.insert(journey.first).inserted else { continue }
            let open = journey.members.allSatisfy {
                let stay = timeline.stays[$0]
                return (stay.mode == .unknown || stay.mode == .ground)
                    && !dismissedCandidates.contains(stay.id)
            }
            guard open, let first = ordered[journey.first].row,
                  let assessment = FlightJudge.assess(journey, in: timeline, airports: airports)
            else { continue }
            let reason: FlightJudge.Reason
            switch FlightJudge.decide(assessment, context: FlightJudge.context(of: journey, in: timeline)) {
            case .record(let judged), .suggest(let judged): reason = judged
            case .none: continue
            }
            let departure = ordered[journey.origin]
            let arrival = ordered[journey.destination]
            guard var record = legRecord(stay: first, previous: departure.endpoint,
                                         lastSeen: assessment.lastSeenAtOrigin, arrival: arrival.endpoint,
                                         nearestAirport: nearestAirport, endAirport: endAirport,
                                         storedDistance: nil)
            else { continue }
            record = hidingHomeAirportCodes(record, previous: departure.endpoint, arrival: arrival.endpoint)
            record.assessment = assessment
            record = withContext(record, stay: first, previous: departure, arrival: arrival,
                                 endAirport: endAirport)
            candidates.append(PossibleFlight(
                record: record,
                evidenceRaw: CandidateEvidence(reason).rawValue,
                gapHours: arrival.endpoint.startTime.timeIntervalSince(assessment.lastSeenAtOrigin) / 3600,
                arrivalIdentifier: first.model.persistentModelID,
                legKm: journey.first == journey.destination ? nil : haversineKm(
                    lat1: departure.endpoint.centroidLatitude, lon1: departure.endpoint.centroidLongitude,
                    lat2: first.centroidLatitude, lon2: first.centroidLongitude)))
        }
        return (records, candidates, endpointStayIDs, recordlessEndpointCodes)
    }

    /// The ends of the flight the stay at `index` holds: its journey's
    /// origin and destination; with more than one flight in the journey,
    /// the stay before it and the stay before the next. Without a journey
    /// (the chain runs out), the leg into the stay. `journey` is the stretch
    /// the judge measures for the detail sheet.
    private static func flightEnds(
        of index: Int, in timeline: FlightJudge.Timeline
    ) -> (departure: Int?, arrival: Int, journey: FlightJudge.Journey?) {
        guard let whole = timeline.journey(containing: index) else {
            return (timeline.previous[index], index, nil)
        }
        let flights = whole.members.filter { timeline.stays[$0].mode == .flight }
        guard let position = flights.firstIndex(of: index) else {
            return (timeline.previous[index], index, nil)
        }
        let departure = position == 0 ? whole.origin : timeline.previous[index] ?? whole.origin
        let arrival = position == flights.count - 1
            ? whole.destination
            : timeline.previous[flights[position + 1]] ?? index
        let chain = [whole.origin] + whole.members
        guard let from = chain.firstIndex(of: departure), let to = chain.firstIndex(of: arrival), from < to else {
            return (departure, arrival, nil)
        }
        return (departure, arrival, FlightJudge.Journey(origin: departure, members: Array(chain[(from + 1)...to])))
    }

    /// Shared leg-record builder for real flights and candidates: route
    /// codes from `endAirport` (the airport whose ring holds the end, else
    /// the one that likely served it), airport-to-airport distance when
    /// both resolve, else `storedDistance` (the stored leg value, when it
    /// measured this leg), else raw centroid geometry. nil when the leg has
    /// no usable geometry at all (JSON-import edge: a row restored without
    /// its predecessor or stored distance). Countries come from an airport
    /// only when the end is in its ring. The window opens at the departure's
    /// end, or for a photo stay at `lastSeen`, the judge's last fix there
    /// (its stored end runs on into the silence after the photo). The arrival
    /// side (airport, place, country, zone, start) is `arrival`'s, the
    /// journey's destination; the id is always `stay`'s, the stay holding
    /// the leg.
    private static func legRecord(
        stay: StayRow,
        previous: Endpoint?,
        lastSeen: Date?,
        arrival: Endpoint,
        nearestAirport: AirportResolver,
        endAirport: EndAirportResolver,
        storedDistance: Double?
    ) -> FlightRecord? {
        let arrivalCoordinate = CLLocationCoordinate2D(latitude: arrival.centroidLatitude,
                                                       longitude: arrival.centroidLongitude)
        let departureCoordinate = previous.map {
            CLLocationCoordinate2D(latitude: $0.centroidLatitude, longitude: $0.centroidLongitude)
        }
        let arrivalRecord = endAirport(arrival, previous)
        let departureRecord = previous.flatMap { endAirport($0, arrival) }
        let arrivalRing = nearestAirport(arrivalCoordinate)
        let departureRing = departureCoordinate.flatMap(nearestAirport)
        // A photo stay's end is its last photo plus the clustering extension
        // into the silence after it (up to 12 h): the window opens at the
        // photo. A live stay's end may be a visit's departure, kept.
        let windowStart = previous.map { $0.isPhoto ? min(lastSeen ?? $0.endTime, $0.endTime) : $0.endTime }

        let distanceKm: Double
        if let dep = departureRecord, let arr = arrivalRecord {
            distanceKm = haversineKm(lat1: dep.lat, lon1: dep.lon,
                                     lat2: arr.lat, lon2: arr.lon)
        } else if let storedDistance {
            distanceKm = storedDistance
        } else if let prev = previous {
            distanceKm = haversineKm(lat1: prev.centroidLatitude,
                                     lon1: prev.centroidLongitude,
                                     lat2: arrival.centroidLatitude,
                                     lon2: arrival.centroidLongitude)
        } else {
            return nil
        }

        let departureISO = departureRing?.iso ?? previous?.isoCountryCode
        let arrivalISO = arrivalRing?.iso ?? arrival.isoCountryCode
        let isInternational: Bool?
        if let dep = departureISO, let arr = arrivalISO {
            isInternational = dep != arr
        } else {
            isInternational = nil
        }

        let departureLon = departureRecord?.lon ?? previous?.centroidLongitude
        let arrivalLon = arrivalRecord?.lon ?? arrival.centroidLongitude
        let tzCrossed = departureLon.map { timeZonesCrossed(lon1: $0, lon2: arrivalLon) } ?? 0

        let overnight: Bool
        if let prev = previous, let depLon = departureLon,
           arrival.startTime.timeIntervalSince(prev.endTime) <= overnightMaxWindowSeconds {
            overnight = intervalCrossesSolarHour(
                start: prev.endTime, end: arrival.startTime,
                longitude: depLon, hour: 2
            )
        } else {
            // No predecessor, or a window too wide to pin a red-eye
            // (photo-era legs) — never fabricate the overnight claim.
            overnight = false
        }

        return FlightRecord(
            id: stay.id,
            departureCode: departureRecord?.code,
            arrivalCode: arrivalRecord?.code,
            departurePlace: previous.flatMap(placeName(for:)),
            arrivalPlace: placeName(for: arrival),
            departureISO: departureISO,
            arrivalISO: arrivalISO,
            date: arrival.startTime,
            distanceKm: distanceKm,
            estimatedHours: estimatedHours(distanceKm: distanceKm),
            isInternational: isInternational,
            timeZonesCrossed: tzCrossed,
            isOvernight: overnight,
            departureWindowStart: windowStart,
            departureTimeZoneIdentifier: previous?.timeZoneIdentifier,
            arrivalTimeZoneIdentifier: arrival.timeZoneIdentifier
        )
    }

    /// An endpoint at the house shows its place name, never the code of an
    /// airport whose ring holds the house: living next to a field is not
    /// flying from it, and the Airports list already leaves such stays out.
    /// Distance and the judge keep the resolved airports.
    private static func hidingHomeAirportCodes(
        _ record: FlightRecord, previous: Endpoint?, arrival: Endpoint
    ) -> FlightRecord {
        var record = record
        if previous?.isHomeAtAirport == true { record.departureCode = nil }
        if arrival.isHomeAtAirport { record.arrivalCode = nil }
        return record
    }

    /// The detail sheet's context for a judged leg: airport names (only for
    /// the codes the route shows), the points its map joins, the stays'
    /// spans on either side, home ends and trips. `previous` is the stay the
    /// record's window was built on.
    private static func withContext(
        _ record: FlightRecord, stay: StayRow, previous: WalkStay?, arrival: WalkStay,
        endAirport: EndAirportResolver
    ) -> FlightRecord {
        var record = record
        let homeRaw = StayCategory.home.rawValue
        let end = arrival.endpoint
        // The airport whose code the route shows, resolved from the stay
        // that code came from.
        let arrivalAirport = record.arrivalCode.flatMap { code in
            endAirport(end, previous?.endpoint)
                .flatMap { $0.code == code ? $0 : nil }
        }
        record.arrivalAirportName = arrivalAirport?.name
        record.arrivalLatitude = arrivalAirport?.lat ?? end.centroidLatitude
        record.arrivalLongitude = arrivalAirport?.lon ?? end.centroidLongitude
        record.arrivalStayEnd = end.endTime
        // A backlog stay (`predecessorOnly`) has no category or trip yet.
        record.arrivalIsHome = arrival.row?.categoryRaw == homeRaw
        record.arrivalTripID = arrival.row?.model.trip?.id ?? stay.model.trip?.id

        guard let previous else { return record }
        let start = previous.endpoint
        let departureAirport = record.departureCode.flatMap { code in
            endAirport(start, end)
                .flatMap { $0.code == code ? $0 : nil }
        }
        record.departureAirportName = departureAirport?.name
        record.departureLatitude = departureAirport?.lat ?? start.centroidLatitude
        record.departureLongitude = departureAirport?.lon ?? start.centroidLongitude
        record.departureStayStart = start.startTime
        if let row = previous.row {
            record.departureIsHome = row.categoryRaw == homeRaw
            record.departureTripID = row.model.trip?.id
        }
        return record
    }

    private static func flightStats(from flights: [FlightRecord]) -> FlightStats {
        var stats = FlightStats()
        var routeCounts: [String: Int] = [:]
        var longest: FlightRecord.Leg?

        for flight in flights {
            // Each leg through the user's stops is a flight of its own; the
            // journey-level marks (international, overnight, time zones)
            // count once.
            let legs = flight.legs
            stats.totalFlights += legs.count
            stats.totalKm += legs.reduce(0) { $0 + $1.distanceKm }
            // The user's times where they set them (`flightHours`).
            stats.totalEstimatedHours += flight.flightHours
            if flight.isInternational == true { stats.internationalCount += 1 }
            if flight.flewOvernight { stats.overnightCount += 1 }
            stats.timeZonesCrossedTotal += flight.timeZonesCrossed
            for leg in legs {
                if leg.distanceKm > (longest?.distanceKm ?? 0) { longest = leg }
                // Unordered pair — ATH→AMS and AMS→ATH are one route, so the
                // label wears the two-way arrow ("AMS ↔ ATH"), never a dash.
                // Codes only: place-name fallbacks are too lossy to key a superlative.
                if let dep = leg.fromCode, let arr = leg.toCode {
                    routeCounts[[dep, arr].sorted().joined(separator: " \u{2194} "), default: 0] += 1
                }
            }
        }
        stats.longestKm = longest?.distanceKm ?? 0
        stats.longestRouteLabel = longest?.routeLabel
        // Count desc, label asc — hash-randomized Dictionary iteration must
        // not flip the winner between launches (the countryStats lesson).
        if let top = routeCounts.max(by: { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key > rhs.key
        }) {
            stats.mostFlownRouteLabel = top.key
            stats.mostFlownRouteCount = top.value
        }
        return stats
    }

    // MARK: - Places

    #if DEBUG
    /// Test seam over `placeEntries`: the homonym split is a property of this
    /// grouping alone and is pinned without building a whole aggregate.
    static func placeEntriesForTesting(byStart: [Stay]) -> [PlaceEntry] {
        placeEntries(byStart: byStart.map { StayRow($0) }, checkCancellation: {})
    }
    #endif

    private static func placeEntries(
        byStart: [StayRow], checkCancellation: () throws -> Void
    ) rethrows -> [PlaceEntry] {
        try checkCancellation()
        let destinationRaw = StayCategory.destination.rawValue
        // Trip members only: the confidence gate keeps sub-θ errand groups
        // permanently tripless as `.destination` residue, which would mint
        // phantom Places rows in the user's own city (tripCount
        // 0) and inflate the home metro row's stay/day counts. Newly
        // classified real stays are tripless only until the next assembly
        // pass — a transient the Stats tab already tolerates.
        let destinations = byStart.filter { $0.categoryRaw == destinationRaw && $0.tripID != nil }

        var entries: [String: PlaceEntry] = [:]
        var tripIDs: [String: Set<UUID>] = [:]
        var days: [String: Set<Date>] = [:]
        var order: [String] = []
        var unnamed: [StayRow] = []

        let adoptedIslands = try adoptedIslandNames(destinations: destinations, checkCancellation: checkCancellation)
        // Which (name, ISO) pairs are genuinely ambiguous WITHIN one country
        // Keying on `name|ISO` alone would merge two different towns that
        // share a name — Agios Nikolaos in Crete and Agios Nikolaos in
        // Halkidiki both geocode to "Agios Nikolaos"/GR with no metro or
        // island name, so the Places list would show ONE row combining both,
        // with summed trips and visit days.
        //
        // Only pairs that actually carry CONFLICTING admin areas get qualified.
        // Adding the admin area to every key would have the opposite failure:
        // one real place whose admin area the geocoder resolves inconsistently
        // (present on some stays, nil on others) would split into duplicate
        // rows. Unambiguous places therefore keep a byte-identical key.
        let ambiguousNameISOPairs = try ambiguousLocalityKeys(
            destinations: destinations,
            adoptedIslands: adoptedIslands,
            checkCancellation: checkCancellation
        )

        for (position, stay) in destinations.enumerated() {
            try checkCancellation()
            // The same precedence as `Stay.placeGroupName` (metro → island
            // → locality), with the port-geocode heal slotted between
            // island and locality. The resolver itself names a port stay's
            // island through its nearest town, so the heal is a safety net
            // for stays with no locality at all.
            let named: (name: String, kind: PlaceKind)?
            if let metro = stay.metroName, !metro.isEmpty {
                named = (metro, .metro)
            } else if let island = stay.islandName, !island.isEmpty {
                named = (island, .island)
            } else if let adopted = adoptedIslands[position] {
                // Port-geocode heal: the stay missed the island polygon but
                // sits within a few km of stays that didn't — it belongs to
                // that island, with its locality nested like any other.
                named = (adopted, .island)
            } else if let locality = stay.locality, !locality.isEmpty {
                named = (locality, .locality)
            } else {
                named = nil
            }
            guard let (name, kind) = named else {
                unnamed.append(stay)
                continue
            }
            var key = "\(name)|\(stay.isoCountryCode ?? "")"
            if ambiguousNameISOPairs.contains(key) {
                // Qualify with the admin area so the homonyms separate. A stay
                // with no admin area keeps its own row rather than being
                // guessed into one of them.
                key += "|\(stay.administrativeArea ?? "")"
            }
            try accumulate(stay: stay, name: name, kind: kind, key: key,
                       iso: stay.isoCountryCode, country: stay.country,
                       entries: &entries, tripIDs: &tripIDs, days: &days, order: &order,
                       checkCancellation: checkCancellation)
        }

        // Fold geocode-degraded nil-ISO entries into a same-named sibling
        // that does carry a country (one sibling only — ambiguous same-name
        // multi-country entries stay separate rather than guess).
        try foldNilISOEntries(entries: &entries, tripIDs: &tripIDs, days: &days, order: &order,
                       checkCancellation: checkCancellation)

        // Un-geocoded stays: 25 km union-find clusters labelled from admin
        // area / country so every destination stay is represented.
        try appendAreaClusters(unnamed: unnamed, entries: &entries,
                           tripIDs: &tripIDs, days: &days, order: &order,
                           checkCancellation: checkCancellation)

        return order.compactMap { key -> PlaceEntry? in
            guard var entry = entries[key] else { return nil }
            entry.tripCount = tripIDs[key]?.count ?? 0
            entry.dayCount = days[key]?.count ?? 0
            return entry
        }
        .sorted { lhs, rhs in
            if lhs.tripCount != rhs.tripCount { return lhs.tripCount > rhs.tripCount }
            if lhs.dayCount != rhs.dayCount { return lhs.dayCount > rhs.dayCount }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func accumulate(
        stay: StayRow,
        name: String,
        kind: PlaceKind,
        key: String,
        iso: String?,
        country: String?,
        entries: inout [String: PlaceEntry],
        tripIDs: inout [String: Set<UUID>],
        days: inout [String: Set<Date>],
        order: inout [String],
        checkCancellation: () throws -> Void
    ) rethrows {
        if var entry = entries[key] {
            entry.stayCount += 1
            entry.firstVisit = min(entry.firstVisit, stay.startTime)
            entry.lastVisit = max(entry.lastVisit, stay.endTime)
            entry.kind = max(entry.kind, kind)
            if let locality = stay.locality, !locality.isEmpty, locality != name,
               !entry.localities.contains(locality) {
                entry.localities.append(locality)
            }
            entries[key] = entry
        } else {
            var localities: [String] = []
            if let locality = stay.locality, !locality.isEmpty, locality != name {
                localities.append(locality)
            }
            entries[key] = PlaceEntry(
                id: key, name: name, isoCountryCode: iso, country: country,
                kind: kind, tripCount: 0, stayCount: 1, dayCount: 0,
                firstVisit: stay.startTime, lastVisit: stay.endTime,
                localities: localities
            )
            order.append(key)
        }
        if let tripID = stay.tripID {
            tripIDs[key, default: []].insert(tripID)
        }
        let zone = StayTimeZone.resolve(stay.timeZoneIdentifier, fallback: utcZone)
        for day in try utcDays(start: stay.startTime, end: stay.endTime, zone: zone,
                               checkCancellation: checkCancellation) {
            days[key, default: []].insert(day)
        }
    }

    /// Candidate buckets on the unit sphere. A radius-r arc has chord length
    /// 2*sin(r/(2*6371)); each Cartesian coordinate differs by at most that
    /// chord, so every match lies in the same or an adjacent cell on each axis.
    /// This avoids broad same-latitude scans without longitude seams or polar
    /// exceptions. Haversine remains the final decision. Dense neighbouring
    /// buckets can still enumerate quadratic pairs.
    struct ProximityBuckets {
        private struct Cell: Hashable {
            let x: Int
            let y: Int
            let z: Int
        }

        private let cellWidth: Double
        private var buckets: [Cell: [Int]] = [:]

        init(rows: [StayRow], radiusKm: Double, checkCancellation: () throws -> Void) rethrows {
            try checkCancellation()
            // A tiny outward margin keeps floating-point boundary rounding
            // from excluding a pair exactly on the accepted radius.
            cellWidth = 2 * sin(radiusKm / (2 * 6_371.0)) + 1e-12
            for (index, stay) in rows.enumerated() {
                try checkCancellation()
                if let cell = cell(latitude: stay.centroidLatitude,
                                   longitude: stay.centroidLongitude) {
                    buckets[cell, default: []].append(index)
                }
            }
        }

        func candidates(latitude: Double, longitude: Double) -> [Int] {
            candidates(latitude: latitude, longitude: longitude, checkCancellation: {})
        }

        func candidates(
            latitude: Double, longitude: Double, checkCancellation: () throws -> Void
        ) rethrows -> [Int] {
            try checkCancellation()
            guard let center = cell(latitude: latitude, longitude: longitude) else { return [] }
            var result: [Int] = []
            for dx in -1...1 {
                for dy in -1...1 {
                    for dz in -1...1 {
                        let neighbour = Cell(x: center.x + dx, y: center.y + dy, z: center.z + dz)
                        try checkCancellation()
                        if let members = buckets[neighbour] {
                            for member in members {
                                try checkCancellation()
                                result.append(member)
                            }
                        }
                    }
                }
            }
            return result
        }

        private func cell(latitude: Double, longitude: Double) -> Cell? {
            guard latitude.isFinite, longitude.isFinite else { return nil }
            let lat = latitude * (.pi / 180)
            let lon = longitude * (.pi / 180)
            let cosLat = cos(lat)
            return Cell(x: Int(floor(cosLat * cos(lon) / cellWidth)),
                        y: Int(floor(cosLat * sin(lon) / cellWidth)),
                        z: Int(floor(sin(lat) / cellWidth)))
        }
    }

    /// The island-adoption map for the port heal: stays with neither metro
    /// nor island name adopt the islandName of the NEAREST same-country
    /// stay within `islandAdoptionRadiusKm`. Read-only — the heal informs
    /// grouping and never writes the `Stay`. Ties break on distance then
    /// donor id, so two devices heal identically. (The winner is min-by-
    /// (distance, donorID), so donor ITERATION ORDER cannot change it —
    /// which makes the sphere-bucket cull a pure optimization;
    /// `CollectionsProximityOracleTests` pins equality with the all-pairs
    /// reference.) Internal, not private: the oracle test drives it directly.
    static func adoptedIslandNames(destinations: [Stay]) -> [PersistentIdentifier: String] {
        adoptedIslandNames(destinations: destinations, checkCancellation: {})
    }

    static func adoptedIslandNames(
        destinations: [Stay], checkCancellation: () throws -> Void
    ) rethrows -> [PersistentIdentifier: String] {
        let adopted = try adoptedIslandNames(destinations: destinations.map { StayRow($0) },
                                             checkCancellation: checkCancellation)
        return Dictionary(adopted.map { (destinations[$0.key].persistentModelID, $0.value) },
                          uniquingKeysWith: { first, _ in first })
    }

    /// Keyed by position in `destinations`: each row is one physical stay,
    /// so UUID twins keep their own adoption.
    private static func adoptedIslandNames(
        destinations: [StayRow], checkCancellation: () throws -> Void
    ) rethrows -> [Int: String] {
        try checkCancellation()
        let donors = try destinations.filter {
            try checkCancellation()
            return $0.islandName?.isEmpty == false
        }
        guard !donors.isEmpty else { return [:] }
        let index = try ProximityBuckets(rows: donors, radiusKm: islandAdoptionRadiusKm,
                                         checkCancellation: checkCancellation)
        var adopted: [Int: String] = [:]
        for (position, stay) in destinations.enumerated() {
            try checkCancellation()
            guard (stay.metroName ?? "").isEmpty, (stay.islandName ?? "").isEmpty else { continue }
            var best: (name: String, distanceKm: Double, donorID: String)?
            for donorIndex in try index.candidates(latitude: stay.centroidLatitude,
                                                    longitude: stay.centroidLongitude,
                                                    checkCancellation: checkCancellation) {
                try checkCancellation()
                let donor = donors[donorIndex]
                if let a = stay.isoCountryCode, let b = donor.isoCountryCode, a != b { continue }
                let d = haversineKm(
                    lat1: stay.centroidLatitude, lon1: stay.centroidLongitude,
                    lat2: donor.centroidLatitude, lon2: donor.centroidLongitude
                )
                guard d <= islandAdoptionRadiusKm, let name = donor.islandName else { continue }
                if let current = best {
                    // Tie-break by (distance, donorID, name). The name key
                    // makes the choice TOTAL even for CloudKit-duplicated
                    // donors sharing a UUID at byte-equal distance — without
                    // it, iteration order decided that degenerate case, so
                    // bucket traversal could pick a different island
                    // than an all-pairs walk.
                    if d < current.distanceKm
                        || (d == current.distanceKm && donor.id.uuidString < current.donorID)
                        || (d == current.distanceKm && donor.id.uuidString == current.donorID
                            && name < current.name) {
                        best = (name, d, donor.id.uuidString)
                    }
                } else {
                    best = (name, d, donor.id.uuidString)
                }
            }
            if let best { adopted[position] = best.name }
        }
        return adopted
    }

    /// `(name, ISO)` keys whose stays carry more than one distinct, non-nil
    /// `administrativeArea` — i.e. same name, same country, demonstrably
    /// different places. Only `.locality`-named stays participate: a metro or
    /// island name is already specific, and metros legitimately span admin
    /// boundaries, so qualifying those would split a single real metro.
    private static func ambiguousLocalityKeys(
        destinations: [StayRow],
        adoptedIslands: [Int: String],
        checkCancellation: () throws -> Void
    ) rethrows -> Set<String> {
        var adminAreasByKey: [String: Set<String>] = [:]
        for (position, stay) in destinations.enumerated() {
            try checkCancellation()
            // Mirror the naming precedence below; only the locality tier is
            // eligible.
            if let metro = stay.metroName, !metro.isEmpty { continue }
            if let island = stay.islandName, !island.isEmpty { continue }
            if adoptedIslands[position] != nil { continue }
            guard let locality = stay.locality, !locality.isEmpty else { continue }
            guard let admin = stay.administrativeArea, !admin.isEmpty else { continue }
            adminAreasByKey["\(locality)|\(stay.isoCountryCode ?? "")", default: []].insert(admin)
        }
        return Set(adminAreasByKey.filter { $0.value.count > 1 }.keys)
    }

    private static func foldNilISOEntries(
        entries: inout [String: PlaceEntry],
        tripIDs: inout [String: Set<UUID>],
        days: inout [String: Set<Date>],
        order: inout [String],
        checkCancellation: () throws -> Void
    ) rethrows {
        let nilISOKeys = entries.keys.filter { $0.hasSuffix("|") }.sorted()
        for key in nilISOKeys {
            try checkCancellation()
            guard let orphan = entries[key] else { continue }
            // `$0.id != orphan.id`: an EMPTY-STRING isoCountryCode builds the
            // same "name|" key as nil but a non-nil entry field, so without it
            // the orphan would match itself as its own unique sibling, merge
            // into itself (doubling counts), and the cleanup below would
            // delete the row outright.
            let siblings = try entries.values.filter {
                try checkCancellation()
                return $0.id != orphan.id && $0.name == orphan.name
                    && ($0.isoCountryCode?.isEmpty == false)
            }
            guard siblings.count == 1, let sibling = siblings.first else { continue }
            var merged = sibling
            merged.stayCount += orphan.stayCount
            merged.firstVisit = min(merged.firstVisit, orphan.firstVisit)
            merged.lastVisit = max(merged.lastVisit, orphan.lastVisit)
            merged.kind = max(merged.kind, orphan.kind)
            for locality in orphan.localities where !merged.localities.contains(locality) {
                try checkCancellation()
                merged.localities.append(locality)
            }
            entries[merged.id] = merged
            tripIDs[merged.id, default: []].formUnion(tripIDs[key] ?? [])
            days[merged.id, default: []].formUnion(days[key] ?? [])
            entries[key] = nil
            tripIDs[key] = nil
            days[key] = nil
            order.removeAll { $0 == key }
        }
    }

    // Internal, not private: `CollectionsProximityOracleTests` compares the
    // sphere-bucket pair scan against an all-pairs reference on randomized
    // inputs by driving this directly.
    static func appendAreaClusters(
        unnamed: [Stay], entries: inout [String: PlaceEntry],
        tripIDs: inout [String: Set<UUID>], days: inout [String: Set<Date>],
        order: inout [String]
    ) {
        appendAreaClusters(unnamed: unnamed, entries: &entries, tripIDs: &tripIDs,
                           days: &days, order: &order, checkCancellation: {})
    }

    static func appendAreaClusters(
        unnamed: [Stay],
        entries: inout [String: PlaceEntry],
        tripIDs: inout [String: Set<UUID>],
        days: inout [String: Set<Date>],
        order: inout [String],
        checkCancellation: () throws -> Void
    ) rethrows {
        // Any category: the seam reads trip and zone from every stay it gets.
        try appendAreaClusters(unnamed: unnamed.map { StayRow($0, anyCategory: true) },
                               entries: &entries, tripIDs: &tripIDs, days: &days, order: &order,
                               checkCancellation: checkCancellation)
    }

    private static func appendAreaClusters(
        unnamed: [StayRow],
        entries: inout [String: PlaceEntry],
        tripIDs: inout [String: Set<UUID>],
        days: inout [String: Set<Date>],
        order: inout [String],
        checkCancellation: () throws -> Void
    ) rethrows {
        // A cluster needs a sub-country label to be a place. Stays whose
        // geocode is country-only (or empty) are dropped entirely. Sea-ping
        // clusters can carry only a country label, which does not identify
        // a place the user visited.
        let unnamed = try unnamed.filter {
            try checkCancellation()
            if let admin = $0.administrativeArea, !admin.isEmpty { return true }
            return false
        }
        guard !unnamed.isEmpty else { return }
        // Exact radius edges over nearby sphere buckets. Rooting every
        // component at its minimum ORIGINAL index preserves labels and keys
        // regardless of bucket traversal order (the all-pairs oracle pins it).
        var parent = Array(0..<unnamed.count)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        let index = try ProximityBuckets(rows: unnamed, radiusKm: areaClusterThresholdKm,
                                         checkCancellation: checkCancellation)
        for i in unnamed.indices {
            try checkCancellation()
            for j in try index.candidates(latitude: unnamed[i].centroidLatitude,
                                          longitude: unnamed[i].centroidLongitude,
                                          checkCancellation: checkCancellation) where j > i {
                try checkCancellation()
                let ri = find(i), rj = find(j)
                // Dense clusters need no further distance checks once an
                // earlier path already connected these two members.
                guard ri != rj else { continue }
                let d = haversineKm(
                    lat1: unnamed[i].centroidLatitude, lon1: unnamed[i].centroidLongitude,
                    lat2: unnamed[j].centroidLatitude, lon2: unnamed[j].centroidLongitude
                )
                if d <= areaClusterThresholdKm { parent[max(ri, rj)] = min(ri, rj) }
            }
        }
        var clusters: [Int: [StayRow]] = [:]
        for i in 0..<unnamed.count {
            try checkCancellation()
            clusters[find(i), default: []].append(unnamed[i])
        }
        // Root index ascending — unnamed is byStart-ordered, so cluster
        // labels and ids are stable across recomputes.
        var clusterIndex = 0
        for root in clusters.keys.sorted() {
            try checkCancellation()
            guard let members = clusters[root] else { continue }
            // Every member has an adminArea (filtered above), so the label
            // never falls back to a bare country name.
            guard let label = mostFrequent(members.compactMap { $0.administrativeArea }) else { continue }
            let iso = mostFrequent(members.compactMap { $0.isoCountryCode })
            let country = mostFrequent(members.compactMap { $0.country })
            // Index-suffixed id: two distinct clusters may share an admin-
            // area label; List identity must not collide.
            let key = "area#\(clusterIndex)|\(label)|\(iso ?? "")"
            clusterIndex += 1
            for stay in members {
                try checkCancellation()
                try accumulate(stay: stay, name: label, kind: .area, key: key,
                           iso: iso, country: country,
                           entries: &entries, tripIDs: &tripIDs, days: &days, order: &order,
                       checkCancellation: checkCancellation)
            }
        }
    }

    // MARK: - Shared helpers

    /// The canonical place-name chain, extended with admin-area/country for
    /// flight-endpoint display fallbacks.
    private static func placeName(for stay: Endpoint) -> String? {
        let candidates = [stay.metroName, stay.islandName, stay.locality,
                          stay.administrativeArea, stay.country]
        return candidates.compactMap { $0 }.first { !$0.isEmpty }
    }

    private static func mostFrequent(_ values: [String]) -> String? {
        guard !values.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for value in values where !value.isEmpty { counts[value, default: 0] += 1 }
        // Count desc, value asc — deterministic under hash randomization.
        return counts.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key > rhs.key
        }?.key
    }

    /// `TravelDays` civil-date labels in `zone` covered by [start, end] — in
    /// UTC a stay from Jul 1 22:00 to Jul 2 09:00 covers two days. Bounded by
    /// `maxDaysPerStay`.
    static func utcDays(
        start: Date, end: Date, zone: TimeZone = TimeZone(secondsFromGMT: 0)!
    ) -> [Date] {
        utcDays(start: start, end: end, zone: zone, checkCancellation: {})
    }

    static func utcDays(
        start: Date, end: Date, zone: TimeZone = TimeZone(secondsFromGMT: 0)!,
        checkCancellation: () throws -> Void
    ) rethrows -> [Date] {
        guard end >= start,
              var day = TravelDays.label(for: start, zone: zone),
              let last = TravelDays.label(for: end, zone: zone) else { return [] }
        let calendar = TravelDays.labelCalendar
        var result: [Date] = []
        while day <= last, result.count < maxDaysPerStay {
            try checkCancellation()
            result.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    /// Great-circle distance in km. Antimeridian-safe (spherical trig).
    static func haversineKm(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let earthRadiusKm = 6_371.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180)
            * sin(dLon / 2) * sin(dLon / 2)
        return earthRadiusKm * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    /// Solar time zones spanned — wraps the antimeridian (179°E → 179°W is
    /// one zone, not 23).
    static func timeZonesCrossed(lon1: Double, lon2: Double) -> Int {
        var delta = abs(lon1 - lon2)
        if delta > 180 { delta = 360 - delta }
        return Int((delta / 15).rounded())
    }

    /// True when the [start, end] interval contains `hour`:00 in solar-local
    /// time at `longitude` (offset = lon/15 hours from UTC). Used for the
    /// overnight-flight heuristic (crossing 02:00 at the departure point).
    static func intervalCrossesSolarHour(start: Date, end: Date, longitude: Double, hour: Int) -> Bool {
        guard end > start else { return false }
        let offset = longitude / 15 * 3600
        let s = start.timeIntervalSince1970 + offset
        let e = end.timeIntervalSince1970 + offset
        if e - s >= 86_400 { return true }
        let target = Double(hour) * 3600
        // Positive modulo — timestamps shifted west of Greenwich pre-1970
        // would otherwise go negative (not reachable with real data, cheap
        // to make total).
        func dayseconds(_ t: Double) -> Double {
            let m = t.truncatingRemainder(dividingBy: 86_400)
            return m < 0 ? m + 86_400 : m
        }
        let sDay = dayseconds(s)
        let eDay = dayseconds(e)
        if sDay <= eDay {
            return target >= sDay && target <= eDay
        } else {
            // Interval wraps midnight.
            return target >= sDay || target <= eDay
        }
    }
}

// MARK: - FlightCandidateDismissals

/// Persistent dismissed-candidate set for the flight review queue. A
/// dismissed leg is never re-suggested (the persistent title-failure-set
/// precedent). Keyed by the ARRIVAL stay's UUID — the same identity as
/// `PossibleFlight.id` — so a dismissal survives recomputes and reinstalls
/// of the aggregate but not a Reclassify-All (which preserves stay ids).
/// UserDefaults-backed: thread-safe, tiny (bounded by the user's real
/// travel), device-local (a deliberate choice — reviewing once per device
/// is cheap, and syncing a UI judgment through CloudKit isn't worth a
/// schema entity).
nonisolated enum FlightCandidateDismissals {
    static let defaultsKey = "dismissedFlightCandidates_v1"

    static func all() -> Set<UUID> {
        let raw = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    static func dismiss(_ id: UUID) {
        var raw = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        guard !raw.contains(id.uuidString) else { return }
        raw.append(id.uuidString)
        UserDefaults.standard.set(raw, forKey: defaultsKey)
    }

    /// The Flight Log's Undo of a dismissal.
    static func undismiss(_ id: UUID) {
        var raw = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        guard raw.contains(id.uuidString) else { return }
        raw.removeAll { $0 == id.uuidString }
        UserDefaults.standard.set(raw, forKey: defaultsKey)
    }
}

extension CollectionsAggregator.AirportEntry {
    /// Synthesized but for `connectionCount`, which a snapshot written
    /// before stops existed lacks.
    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            code: try container.decode(String.self, forKey: .code),
            name: try container.decodeIfPresent(String.self, forKey: .name),
            city: try container.decodeIfPresent(String.self, forKey: .city),
            isoCountryCode: try container.decodeIfPresent(String.self, forKey: .isoCountryCode),
            hasScheduledService: try container.decode(Bool.self, forKey: .hasScheduledService),
            stayCount: try container.decode(Int.self, forKey: .stayCount),
            firstVisit: try container.decode(Date.self, forKey: .firstVisit),
            lastVisit: try container.decode(Date.self, forKey: .lastVisit),
            flownThrough: try container.decode(Bool.self, forKey: .flownThrough),
            connectionCount: try container.decodeIfPresent(Int.self, forKey: .connectionCount) ?? 0)
    }
}
