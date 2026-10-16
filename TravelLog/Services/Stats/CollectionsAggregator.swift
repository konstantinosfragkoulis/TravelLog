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
//  - **Flights**: the arrival side is the stay carrying
//    `transitFromPreviousRaw == .flight` (that field means "how the user
//    travelled FROM the previous stay"); the departure side is the TRUE
//    chronological predecessor (latest `endTime < arrival.startTime`) at
//    ANY gap — TransitInferer's 7-day lookback is an INFERENCE rule, not a
//    display rule, and a `.flight` value is already vouched (live
//    inference's speed gate makes >7-day gaps impossible; wider gaps only
//    arise on review-queue-confirmed photo-era legs and partial imports,
//    where "the last place we saw you" is the honest departure).
//    Route codes are attributed only when the endpoint stay is itself
//    within the airport radius — we never guess a metropolitan airport
//    from a city-centre stay (London: LHR/LGW/STN would be a coin flip).
//    Durations are ESTIMATES from the standard block-time approximation
//    `hours = km/780 + 0.5` — never presented as measured fact.
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
        /// (vs. merely set foot in — pickup, drop-off, spotting).
        var flownThrough: Bool

        var id: String { code }
    }

    /// One inferred flight leg. `id` is the arrival stay's UUID — stable
    /// across recomputes, so SwiftUI list identity survives refreshes.
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
        /// Arrival stay's `startTime` — when the user was first seen landed.
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
        /// snapshots carry nil, and their rows open nothing).
        var tripID: UUID? = nil
        /// The arrival stay's physical row, so Not a Flight writes to it and
        /// never to a same-id twin. Not persisted, like
        /// `PossibleFlight.arrivalIdentifier`.
        var arrivalIdentifier: PersistentIdentifier? = nil

        private enum CodingKeys: String, CodingKey {
            case id, departureCode, arrivalCode, departurePlace, arrivalPlace,
                 departureISO, arrivalISO, date, distanceKm, estimatedHours,
                 isInternational, timeZonesCrossed, isOvernight, departureWindowStart,
                 departureTimeZoneIdentifier, arrivalTimeZoneIdentifier, tripID
        }

        /// "ATH → AMS", falling back to place names for unresolved ends.
        var routeLabel: String {
            let dep = departureCode ?? departurePlace ?? "?"
            let arr = arrivalCode ?? arrivalPlace ?? "?"
            return String(
                localized: "collections.flight.route",
                defaultValue: "\(dep) → \(arr)",
                comment: "Flight route from departure airport or place to arrival airport or place."
            )
        }

        /// "Syros → Athens" under the codes line: both places known, and
        /// not a repeat of `routeLabel`.
        var placeRouteLabel: String? {
            guard let dep = departurePlace, let arr = arrivalPlace else { return nil }
            let label = String(
                localized: "collections.flight.route",
                defaultValue: "\(dep) → \(arr)",
                comment: "Flight route from departure airport or place to arrival airport or place."
            )
            return label == routeLabel ? nil : label
        }
    }

    /// Why an `.unknown` leg is being offered as a possible flight.
    /// Ordered by evidence strength — a leg matching several tiers reports
    /// the strongest.
    nonisolated enum CandidateEvidence: String, Sendable, Equatable, Codable {
        /// Consecutive stays at two DIFFERENT airports — nobody ferries
        /// airport-to-airport.
        case bothAirports
        /// ≥300 km with an airport endpoint at an effective speed only a
        /// plane sustains (≥140 km/h door-to-door beats any car/ferry;
        /// only airport-adjacent high-speed rail overlaps).
        case fastLeg
        /// Sparse-data mining (photo-era history): a country jump or a
        /// very long leg with no recorded stop between the endpoints. No
        /// speed test — photo gaps are days.
        case countryJump
        /// Sparse-data mining, domestic: the endpoints sit on different
        /// islands (or island ↔ mainland) ≥250 km apart — the Greek-island
        /// flight class the country tiers can't see. Long car-ferry
        /// journeys and bridge-connected islands (Lefkada) are the
        /// expected dismissals.
        case islandHop

        var displayText: String {
            switch self {
            case .bothAirports:
                String(localized: "collections.flight-evidence.airports", defaultValue: "Airport to airport", comment: "Reason a route may be a flight.")
            case .fastLeg:
                String(localized: "collections.flight-evidence.speed", defaultValue: "Too fast for ground travel", comment: "Reason a route may be a flight.")
            case .countryJump:
                String(localized: "collections.flight-evidence.country-jump", defaultValue: "Country-to-country jump", comment: "Reason a route may be a flight.")
            case .islandHop:
                String(localized: "collections.flight-evidence.island-hop", defaultValue: "Island hop", comment: "Reason a route may be a flight.")
            }
        }
    }

    /// A review-queue entry: an `.unknown` leg with flight-shaped evidence.
    /// NEVER auto-written — the user confirms (→ `.flight`, terminal) or
    /// dismisses (persisted via `FlightCandidateDismissals`).
    nonisolated struct PossibleFlight: Sendable, Equatable, Identifiable, Codable {
        let record: FlightRecord
        let evidenceRaw: String
        /// Observed gap between the endpoint stays, for the evidence line.
        let gapHours: Double
        /// The arrival stay's physical row, so Confirm writes to it and never
        /// to a same-id twin. Not persisted: a candidate read back from the
        /// stats snapshot has none until the next aggregate replaces it.
        var arrivalIdentifier: PersistentIdentifier? = nil

        private enum CodingKeys: String, CodingKey {
            case record, evidenceRaw, gapHours
        }

        var id: UUID { record.id }
        var evidence: CandidateEvidence? { CandidateEvidence(rawValue: evidenceRaw) }

        /// The evidence line's reason. `countryJump` also admits long
        /// same-country legs and legs with an unknown country, so it names
        /// a border only when both known countries differ.
        var evidenceDisplayText: String? {
            guard let evidence else { return nil }
            if evidence == .countryJump, record.isInternational != true {
                return String(localized: "collections.flight-evidence.long-distance", defaultValue: "Long distance between stops", comment: "Reason a route may be a flight: a long leg with no recorded stop between, inside one country or between unknown countries.")
            }
            return evidence.displayText
        }
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

    /// Average block speed for the duration estimate. 780 km/h ≈ cruise
    /// minus climb/descent averaging; the +0.5 h constant absorbs taxi and
    /// runway time. Standard flight-time approximation, good to ~±15%.
    private static let estimateBlockSpeedKmh: Double = 780
    private static let estimateFixedOverheadHours: Double = 0.5

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

    // MARK: Probable-flight tiers
    //
    // The certain tier (TransitInferer's gap < km/400 gate) only detects
    // ≳1,600 km flights under typical dwell. These thresholds define the
    // review-queue tiers; none auto-writes anything.

    /// fastLeg: distance floor mirrors the certain tier's.
    private static let fastLegMinDistanceKm: Double = 300
    /// fastLeg: door-to-door effective speed no car (≤~110) or ferry
    /// (≤~50) sustains; a real 300–1,600 km flight nets 140–300 km/h.
    /// Airport-adjacent high-speed rail (CDG/Frankfurt/Schiphol) is the
    /// one overlap — which is why this tier only ever *suggests*.
    private static let fastLegMinEffectiveSpeedKmh: Double = 140
    /// bothAirports: two different airports back-to-back is damning even
    /// short — this floor just keeps out taxi transfers between a city's
    /// own airports (ATH has no 80 km sibling; LGW–STN is ~70 km).
    private static let bothAirportsMinDistanceKm: Double = 80
    /// bothAirports: two airport endpoints already rule out a port-to-port
    /// ferry. At 60 km/h or more any window qualifies; below it (down to
    /// 25 km/h) only a window of up to 4 h does, so ATH–JSY (~105 km) in
    /// 2-3 h is offered while a ferry-day or day-long drive window is not
    /// (ATH–GPA, ~222 km, in 8 h nets 28 km/h). Review-only, like every tier.
    private static let bothAirportsMinEffectiveSpeedKmh: Double = 60
    private static let bothAirportsSlowMinEffectiveSpeedKmh: Double = 25
    private static let bothAirportsSlowMaxGapHours: Double = 4
    /// countryJump: cross-border displacement floor. Below it, cars cross
    /// borders constantly (Munich→Salzburg, Brussels→Paris); above it, an
    /// unbroken hop (no stay in between) is flight-shaped even with a
    /// photo-era day-scale gap. 300 km keeps Athens→Sofia/Istanbul-class
    /// flights; recall is the queue's job, precision is the user's tap.
    private static let countryJumpMinDistanceKm: Double = 300
    /// countryJump: same-country arm (US/AU-scale domestic hops).
    private static let longJumpMinDistanceKm: Double = 1200
    /// islandHop: different-island (or island↔mainland) legs at least this
    /// long. 250 km is past every drive-on/drive-off short ferry; what
    /// remains is flights plus long car ferries the user dismisses once.
    private static let islandHopMinDistanceKm: Double = 250
    /// Ground-mode override: CoreMotion-era `.automotive`/`.mixed` legs
    /// carry a real (if flaky) measurement — the taxi ride often won the
    /// vote over the flight. Only impossible evidence re-opens them:
    /// ≥200 km/h door-to-door is beyond any car including stops.
    private static let groundOverrideMinEffectiveSpeedKmh: Double = 200

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
        dismissedCandidates: Set<UUID> = FlightCandidateDismissals.all()
    ) -> Collections {
        aggregate(stays: stays, predecessorOnlyStays: predecessorOnlyStays,
                  nearestAirport: nearestAirport, dismissedCandidates: dismissedCandidates,
                  checkCancellation: {})
    }

    static func aggregate(
        stays: [Stay],
        predecessorOnlyStays: [Stay] = [],
        nearestAirport: AirportResolver = {
            AirportDetector.shared.nearestAirport($0, radiusMeters: 3000)
        },
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
            nearestAirport: nearestAirport, dismissedCandidates: dismissedCandidates,
            checkCancellation: checkCancellation)
    }

    /// The reduction itself, over fields copied once per stay.
    static func aggregate(
        rows: [StayRow],
        predecessorOnly: [Endpoint],
        nearestAirport: AirportResolver = {
            AirportDetector.shared.nearestAirport($0, radiusMeters: 3000)
        },
        dismissedCandidates: Set<UUID> = FlightCandidateDismissals.all(),
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

        var result = Collections()
        // Flights first: their endpoint stay IDs exempt brief arrival/
        // departure dwells from the set-foot minimum.
        let (flights, candidates, endpointStayIDs, recordlessEndpointCodes) = try flightRecords(
            byStart: byStart,
            predecessorOnly: predecessorOnly,
            nearestAirport: memoizedResolver,
            checkCancellation: checkCancellation
        )
        var airportVisits = try airportEntries(
            byStart: byStart,
            flightEndpointStayIDs: endpointStayIDs,
            nearestAirport: memoizedResolver,
            checkCancellation: checkCancellation
        )

        // Tier pass: an airport that appears as a flight endpoint is
        // flown-through. Codes without a visit entry are deliberately NOT
        // materialized, and a stay at the user's house names no code at
        // all — being near an airport at home is not a visit.
        for flight in flights {
            try checkCancellation()
            if let code = flight.departureCode { airportVisits[code]?.flownThrough = true }
            if let code = flight.arrivalCode { airportVisits[code]?.flownThrough = true }
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
        result.flights = flights.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id.uuidString < $1.id.uuidString
        }
        result.flightStats = flightStats(from: flights)
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

    /// Returns the inferred legs, the review-queue candidates mined from
    /// `.unknown` legs, and the IDs of every stay that served as a REAL
    /// flight endpoint (arrival stay or its predecessor) — those stays are
    /// exempt from the set-foot dwell minimum in `airportEntries`.
    /// Candidates never grant exemptions or materialize airports: they are
    /// suggestions until the user confirms.
    private static func flightRecords(
        byStart: [StayRow],
        predecessorOnly: [Endpoint],
        nearestAirport: AirportResolver,
        checkCancellation: () throws -> Void
    ) rethrows -> (flights: [FlightRecord], candidates: [PossibleFlight], endpointStayIDs: Set<UUID>, recordlessEndpointCodes: Set<String>) {
        let flightRaw = TransitMode.flight.rawValue
        let unknownRaw = TransitMode.unknown.rawValue
        let notFlightRaw = TransitMode.notFlight.rawValue
        // Predecessor lookup sorted by endTime (TransitInferer's rule), with
        // an id tiebreak so equal endTimes resolve identically everywhere.
        // The pool INCLUDES `predecessorOnly`: TransitInferer's
        // `findPreviousStay` has no category filter, so during a
        // classification backlog the leg's TRUE chronological predecessor
        // may still be `.unclassified` — attributing the departure from the
        // nearest CLASSIFIED stay instead would render the wrong
        // route/ISO/timezone/date window until the backlog drained.
        // These stays join only this walk; they never become entries.
        let byEndKeys = (byStart.map { $0.endpoint } + predecessorOnly)
            .map { (endpoint: $0, end: $0.endTime, id: $0.id.uuidString) }
            .sorted {
                if $0.end != $1.end { return $0.end < $1.end }
                return $0.id < $1.id
            }
        let byEnd = byEndKeys.map { $0.endpoint }
        let endTimes = byEndKeys.map { $0.end }

        var records: [FlightRecord] = []
        var candidates: [PossibleFlight] = []
        var endpointStayIDs: Set<UUID> = []
        var recordlessEndpointCodes: Set<String> = []

        for stay in byStart {
            try checkCancellation()
            // nil = unclassified; the pipeline will get to it.
            guard let transitRaw = stay.transitFromPreviousRaw else { continue }
            switch transitRaw {
            case flightRaw:
                let previous = predecessor(of: stay, byEnd: byEnd, endTimes: endTimes)
                endpointStayIDs.insert(stay.id)
                if let previous { endpointStayIDs.insert(previous.id) }
                if var record = legRecord(stay: stay, previous: previous,
                                          nearestAirport: nearestAirport,
                                          preferStoredDistance: true) {
                    record = hidingHomeAirportCodes(record, stay: stay, previous: previous)
                    record.tripID = stay.model.trip?.id
                    record.arrivalIdentifier = stay.model.persistentModelID
                    records.append(record)
                } else {
                    // Geometry-less terminal flight (partial JSON restore /
                    // missing predecessor): the endpoints keep their dwell
                    // exemption — the persisted evidence vouches a flight —
                    // so any endpoint that itself resolves to an airport
                    // must also read flown-through, or the exemption and
                    // the tier contradict each other.
                    if let code = nearestAirport(CLLocationCoordinate2D(
                        latitude: stay.centroidLatitude,
                        longitude: stay.centroidLongitude
                    ))?.code {
                        recordlessEndpointCodes.insert(code)
                    }
                    if let previous,
                       let code = nearestAirport(CLLocationCoordinate2D(
                        latitude: previous.centroidLatitude,
                        longitude: previous.centroidLongitude
                       ))?.code {
                        recordlessEndpointCodes.insert(code)
                    }
                }
            case unknownRaw:
                // Candidate mining deliberately looks PAST TransitInferer's
                // 7-day lookback: photo-era flights are precisely the legs
                // whose endpoints sit days apart (classified via the
                // no-previous branch with a nil distance).
                if let candidate = mineCandidate(stay: stay, byEnd: byEnd, endTimes: endTimes,
                                                 nearestAirport: nearestAirport,
                                                 speedOverrideOnly: false) {
                    candidates.append(candidate)
                }
            case notFlightRaw:
                // The user said this leg was not a flight: never a record,
                // never suggested again.
                break
            default:
                // Legacy CoreMotion-era ground mode: it carries a real (if
                // flaky) measurement, so only the strict speed override may
                // second-guess it — never the sparse tiers.
                if let candidate = mineCandidate(stay: stay, byEnd: byEnd, endTimes: endTimes,
                                                 nearestAirport: nearestAirport,
                                                 speedOverrideOnly: true) {
                    candidates.append(candidate)
                }
            }
        }
        return (records, candidates, endpointStayIDs, recordlessEndpointCodes)
    }

    private static func mineCandidate(
        stay: StayRow,
        byEnd: [Endpoint],
        endTimes: [Date],
        nearestAirport: AirportResolver,
        speedOverrideOnly: Bool
    ) -> PossibleFlight? {
        guard let previous = predecessor(of: stay, byEnd: byEnd, endTimes: endTimes),
              // preferStoredDistance: false — the stored leg value can be
              // STALE when a later photo import inserted stays between the
              // rows it was computed against; candidates always evaluate
              // the true current-predecessor geometry.
              let record = legRecord(stay: stay, previous: previous,
                                     nearestAirport: nearestAirport,
                                     preferStoredDistance: false),
              let evidence = candidateEvidence(record: record, stay: stay,
                                               previous: previous,
                                               speedOverrideOnly: speedOverrideOnly)
        else { return nil }
        let gapHours = stay.startTime.timeIntervalSince(previous.endTime) / 3600
        return PossibleFlight(
            // Codes hidden only after the tiers judged the leg, so the
            // queue's admission is unchanged.
            record: hidingHomeAirportCodes(record, stay: stay, previous: previous),
            evidenceRaw: evidence.rawValue,
            gapHours: gapHours,
            arrivalIdentifier: stay.model.persistentModelID
        )
    }

    /// Shared leg-record builder for real flights and candidates: route
    /// codes only from at-airport endpoints (never guess a metro airport
    /// from a city-centre stay), airport-to-airport distance when both
    /// resolve, else the stored leg value, else raw centroid geometry.
    /// nil when the leg has no usable geometry at all (JSON-import edge:
    /// a row restored without its predecessor or stored distance).
    private static func legRecord(
        stay: StayRow,
        previous: Endpoint?,
        nearestAirport: AirportResolver,
        preferStoredDistance: Bool
    ) -> FlightRecord? {
        let arrivalRecord = nearestAirport(
            CLLocationCoordinate2D(latitude: stay.centroidLatitude,
                                   longitude: stay.centroidLongitude)
        )
        let departureRecord = previous.flatMap { prev in
            nearestAirport(CLLocationCoordinate2D(latitude: prev.centroidLatitude,
                                                  longitude: prev.centroidLongitude))
        }

        let distanceKm: Double
        if let dep = departureRecord, let arr = arrivalRecord {
            distanceKm = haversineKm(lat1: dep.lat, lon1: dep.lon,
                                     lat2: arr.lat, lon2: arr.lon)
        } else if preferStoredDistance, let stored = stay.model.distanceFromPreviousKm {
            distanceKm = stored
        } else if let prev = previous {
            distanceKm = haversineKm(lat1: prev.centroidLatitude,
                                     lon1: prev.centroidLongitude,
                                     lat2: stay.centroidLatitude,
                                     lon2: stay.centroidLongitude)
        } else if let stored = stay.model.distanceFromPreviousKm {
            distanceKm = stored
        } else {
            return nil
        }

        let departureISO = departureRecord?.iso ?? previous?.isoCountryCode
        let arrivalISO = arrivalRecord?.iso ?? stay.isoCountryCode
        let isInternational: Bool?
        if let dep = departureISO, let arr = arrivalISO {
            isInternational = dep != arr
        } else {
            isInternational = nil
        }

        let departureLon = departureRecord?.lon ?? previous?.centroidLongitude
        let arrivalLon = arrivalRecord?.lon ?? stay.centroidLongitude
        let tzCrossed = departureLon.map { timeZonesCrossed(lon1: $0, lon2: arrivalLon) } ?? 0

        let overnight: Bool
        if let prev = previous, let depLon = departureLon,
           stay.startTime.timeIntervalSince(prev.endTime) <= overnightMaxWindowSeconds {
            overnight = intervalCrossesSolarHour(
                start: prev.endTime, end: stay.startTime,
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
            arrivalPlace: placeName(for: stay.endpoint),
            departureISO: departureISO,
            arrivalISO: arrivalISO,
            date: stay.startTime,
            distanceKm: distanceKm,
            estimatedHours: distanceKm / estimateBlockSpeedKmh + estimateFixedOverheadHours,
            isInternational: isInternational,
            timeZonesCrossed: tzCrossed,
            isOvernight: overnight,
            departureWindowStart: previous?.endTime,
            departureTimeZoneIdentifier: previous?.timeZoneIdentifier,
            arrivalTimeZoneIdentifier: stay.endpoint.timeZoneIdentifier
        )
    }

    /// An endpoint at the house shows its place name, never the code of an
    /// airport whose ring holds the house: living next to a field is not
    /// flying from it, and the Airports list already leaves such stays out.
    /// Distance and the review tiers keep the resolved airports.
    private static func hidingHomeAirportCodes(
        _ record: FlightRecord, stay: StayRow, previous: Endpoint?
    ) -> FlightRecord {
        var record = record
        if previous?.isHomeAtAirport == true { record.departureCode = nil }
        if stay.endpoint.isHomeAtAirport { record.arrivalCode = nil }
        return record
    }

    /// Tier evaluation for a mined leg — strongest evidence wins; nil
    /// means "not flight-shaped, don't suggest". `speedOverrideOnly`
    /// restricts legacy ground-mode legs to the impossible-speed arm.
    private static func candidateEvidence(
        record: FlightRecord,
        stay: StayRow,
        previous: Endpoint,
        speedOverrideOnly: Bool
    ) -> CandidateEvidence? {
        let gapHours = stay.startTime.timeIntervalSince(previous.endTime) / 3600
        guard gapHours > 0 else { return nil }
        let effectiveSpeedKmh = record.distanceKm / gapHours

        if speedOverrideOnly {
            if record.distanceKm >= fastLegMinDistanceKm,
               record.departureCode != nil || record.arrivalCode != nil,
               effectiveSpeedKmh >= groundOverrideMinEffectiveSpeedKmh {
                return .fastLeg
            }
            return nil
        }

        if previous.isAirport, stay.isAirport,
           let dep = record.departureCode, let arr = record.arrivalCode, dep != arr,
           record.distanceKm >= bothAirportsMinDistanceKm,
           effectiveSpeedKmh >= bothAirportsMinEffectiveSpeedKmh
            || (gapHours <= bothAirportsSlowMaxGapHours
                && effectiveSpeedKmh >= bothAirportsSlowMinEffectiveSpeedKmh) {
            return .bothAirports
        }
        if record.distanceKm >= fastLegMinDistanceKm,
           record.departureCode != nil || record.arrivalCode != nil,
           effectiveSpeedKmh >= fastLegMinEffectiveSpeedKmh {
            return .fastLeg
        }
        if let dep = record.departureISO, let arr = record.arrivalISO, dep != arr,
           record.distanceKm >= countryJumpMinDistanceKm {
            return .countryJump
        }
        if record.distanceKm >= longJumpMinDistanceKm {
            return .countryJump
        }
        // Different islands (or island ↔ mainland): the domestic
        // island-flight class no country comparison can see.
        let departureIsland = previous.islandName ?? ""
        let arrivalIsland = stay.islandName ?? ""
        if record.distanceKm >= islandHopMinDistanceKm,
           departureIsland != arrivalIsland,
           !departureIsland.isEmpty || !arrivalIsland.isEmpty {
            return .islandHop
        }
        return nil
    }

    /// The true chronological predecessor: latest `endTime < stay.startTime`
    /// at ANY gap. Binary search over the endTime-sorted array (upper bound
    /// of startTime, step back one). Deliberately NOT capped by
    /// `TransitInferer.transitMaxGapSeconds`: the 7-day lookback is an
    /// inference-validity rule, and every leg reaching here is already
    /// vouched (a terminal `.flight`, or a candidate being mined). A cap
    /// would make a review-queue-confirmed photo-era leg lose in the log the
    /// very departure the queue had just shown ("ATH → JSY" confirmed,
    /// "? → Syros" rendered), plus its ISO pair, time zones, and
    /// date-range window.
    private static func predecessor(of stay: StayRow, byEnd: [Endpoint], endTimes: [Date]) -> Endpoint? {
        var low = 0, high = endTimes.count
        while low < high {
            let mid = (low + high) / 2
            if endTimes[mid] < stay.startTime { low = mid + 1 } else { high = mid }
        }
        // `low` is the first index with endTime >= startTime; candidates sit
        // strictly before it. Skip the stay itself (defensive — its endTime
        // >= its startTime keeps it at/after `low` for well-formed rows).
        var index = low - 1
        while index >= 0, byEnd[index].id == stay.id { index -= 1 }
        guard index >= 0 else { return nil }
        return byEnd[index]
    }

    private static func flightStats(from flights: [FlightRecord]) -> FlightStats {
        var stats = FlightStats()
        var routeCounts: [String: Int] = [:]
        var longest: FlightRecord?

        for flight in flights {
            stats.totalFlights += 1
            stats.totalKm += flight.distanceKm
            stats.totalEstimatedHours += flight.estimatedHours
            if flight.isInternational == true { stats.internationalCount += 1 }
            if flight.isOvernight { stats.overnightCount += 1 }
            stats.timeZonesCrossedTotal += flight.timeZonesCrossed
            if flight.distanceKm > (longest?.distanceKm ?? 0) { longest = flight }
            // Unordered pair — ATH→AMS and AMS→ATH are one route, so the
            // label wears the two-way arrow ("AMS ↔ ATH"), never a dash.
            // Codes only: place-name fallbacks are too lossy to key a superlative.
            if let dep = flight.departureCode, let arr = flight.arrivalCode {
                routeCounts[[dep, arr].sorted().joined(separator: " \u{2194} "), default: 0] += 1
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
