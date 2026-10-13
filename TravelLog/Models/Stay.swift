//
//  Stay.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import Foundation
import SwiftData
import CoreLocation

/// A cluster of consecutive `LocationPing` records in approximately the same place.
///
/// Stays are deterministically computed from pings - no AI involved.
/// Classification (home/routine/destination/transit) is applied separately
/// by the trip classification pipeline.
@Model
final class Stay {

    var id: UUID = UUID()

    var startTime: Date = Date.now
    var endTime: Date = Date.now
    var durationMinutes: Int = 0

    /// Centroid of all pings in this stay.
    var centroidLatitude: Double = 0
    var centroidLongitude: Double = 0

    // MARK: - Location Identity (from the dominant ping's geocoding)

    var locality: String?
    var administrativeArea: String?
    var country: String?
    var isoCountryCode: String?

    // MARK: - V10 Offline-Geocoder Fields
    //
    // Optional Strings populated by `GeocodeResolver`. All three are
    // additive nilables; V9-on-disk rows just have nil for these
    // until the auto-backfill re-geocodes them.

    /// Neighborhood / district within a metro. "Karaköy", "Plaka",
    /// "Beverly Hills". Populated from the OSM
    /// `place=neighbourhood / suburb` layer in the bundled
    /// `Geocoder.sqlite`. nil for stays whose centroid doesn't fall in
    /// a tracked neighbourhood; the UI's `subLocality ?? locality`
    /// fallback handles that case. Added in V10.
    var subLocality: String?

    /// Metropolitan-area name. "Athens", "Tokyo", "Los Angeles".
    /// Populated by `GeocodeResolver` via GHS-FUA polygon hit with
    /// gravity-on-FUA-centres fallback (so a coordinate just outside the
    /// Athens FUA polygon can still get "Athens" as its metro). Used by
    /// the Stage 5 trip-title generator. Added in V10.
    var metroName: String?

    /// Island name when the stay's centroid falls inside a named OSM
    /// `place=island` polygon. "Cephalonia", "Mykonos", "Paxos",
    /// "Kauai". Title-generation hint for island visits where
    /// `metroName` is nil. Added in V10.
    var islandName: String?

    /// The one name every place-level consumer groups this stay under:
    /// metro, else island, else locality. Titles, the summary, Places,
    /// Wrapped, On This Day and the Siri intents all read THIS, so a stay
    /// can never be "Athens" on one screen and "Gerakas" on another.
    var placeGroupName: String? {
        metroName ?? islandName ?? locality
    }

    // MARK: - V11 Weather Enrichment

    /// Full weather snapshot encoded as a `StayWeather` Codable struct.
    /// Contains temperature range, precipitation, wind, humidity, dominant
    /// condition. Decoded at render time by the trip timeline popover.
    /// nil = not yet enriched. Added in V11.
    var weatherData: Data?

    /// Average temperature during this stay, in Celsius. Top-level for
    /// queryable aggregation (Wrapped Card 5 "hottest/coldest stay"
    /// without decoding every blob). Added in V11.
    var avgTemperatureC: Double?

    /// Dominant weather condition as raw String. Backs
    /// `StayWeather.Condition` enum ("clear", "rain", "unavailable", etc.).
    /// Top-level for queryable aggregation. nil = not yet enriched;
    /// "unavailable" = permanently unobtainable (pre-Aug-2021 or gap).
    /// Added in V11.
    var weatherConditionRaw: String?

    /// Total precipitation during this stay, in millimeters. Top-level for
    /// queryable aggregation (Wrapped "rainiest trip"). Added in V11.
    var precipitationMm: Double?

    /// UTC start-of-day of this stay's `startTime`. Denormalized for
    /// efficient weather cache predicates: `(h3IndexRes6, dayKey)` narrows
    /// the fetch, and the UTC day span completes the weather validity key.
    /// Added in V11.
    var dayKey: Date?

    // MARK: - V11 Transit Inference

    /// How the user travelled from the previous stay to this one.
    /// Backs `TransitMode` enum. nil = not yet classified. New data holds
    /// `.flight` (geometry) or `.unknown`; legacy ground modes ("automotive",
    /// "walking", …) on older or imported stays are still honoured (see
    /// `TransitMode`). Added in V11.
    var transitFromPreviousRaw: String?

    /// Great-circle distance from the previous stay's centroid to this
    /// stay's centroid, in kilometers. Added in V11.
    var distanceFromPreviousKm: Double?

    /// Steps walked during this stay's duration. Legacy: nil for new stays;
    /// existing and JSON-imported values are still read. Added in V11.
    var stepsWalked: Int?

    // MARK: - V9 Airport Detection

    /// True when the stay's centroid is within ~3 km of a known major airport
    /// (bundled `airports.json`, queried via `AirportDetector`). Set by
    /// `StayClusterer` at stay creation and by the V9 one-time backfill.
    /// Used as a strong signal by `TripClassifier` (heuristic forces transit
    /// for sub-24h airport stays; AI prompt flags the stay) and by the Stage 5
    /// title generator (filters airport-area noise). Added in V9.
    var isAirport: Bool = false

    /// The most common H3 res-6 index among pings in this stay.
    var h3IndexRes6: String = ""

    /// Number of SLC pings that fell into this stay.
    var pingCount: Int = 0

    /// Distance from the user's active home at the time of this stay, in kilometers.
    var distanceFromHomeKm: Double = 0

    // MARK: - Classification

    /// The category assigned by Foundation Models or heuristic fallback.
    var categoryRaw: String = ""

    /// Whether the user manually overrode the AI/heuristic classification.
    var userOverridden: Bool = false

    /// The temporary home that made this stay `.home`, when no real Home
    /// claimed it then. Written with the category by its two home writers and
    /// cleared by `category`'s setter whenever the stay leaves `.home`, so the
    /// two commit and roll back together. A temporary-home reconciliation frees
    /// a home stay only on this evidence; nil (every real-Home stay, and rows
    /// stamped before V20) never authorizes it. Added in V20.
    var temporaryHomeID: UUID?

    /// The `TemporaryHome.coverageRevision` of the declaration copy that
    /// stamped `temporaryHomeID`. One half of a pair: set and cleared with it
    /// (`setTemporaryHomeProvenance(_:revision:)`, `category`'s setter), never
    /// alone. Nil with an id is a stamp written before V21. Added in V21.
    var temporaryHomeRevision: Int?

    /// Whether the AI/heuristic determined this stay is part of the same trip
    /// as the previous non-home/non-routine stay. Set during classification (Stage 2)
    /// and used during trip assembly (Stage 3) to decide trip boundaries.
    var continuesPreviousTrip: Bool = false

    // MARK: - Trip Association

    @Relationship
    var trip: Trip?

    /// Position within the trip's stay sequence (0-indexed).
    var orderInTrip: Int?

    // MARK: - Raw Data Link

    /// References to the `LocationPing.id` values that form this stay.
    /// Stored as comma-separated UUID strings for CloudKit compatibility.
    var pingIDsString: String = ""

    // MARK: - Provenance

    /// Provenance of this stay. Defaults to `"liveSLC"` for V7→V8 lightweight
    /// migration. Set to `"photoImport"` for stays built entirely from
    /// imported photo pings; set to `"merged"` when pings from more than one
    /// provenance contribute to the Stay (most commonly when an imported ping
    /// is folded into a previously-live Stay). Use the `source` computed
    /// property for type-safe access. Added in V8.
    var sourceRaw: String = DataSource.liveSLC.rawValue

    /// IANA zone (or a fixed "GMT±hhmm" offset) of the place this stay
    /// happened in, stamped once at creation: the device's zone for live
    /// observations (the phone was physically there), a longitude-derived
    /// offset for imported history. Read by `Trip.durationDays` so a trip's
    /// day count is taken where its boundary stays happened, not in the
    /// viewing device's zone. Nil on rows written before V18; consumers fall
    /// back to the device zone, the pre-V18 behaviour. Added in V18.
    var timeZoneIdentifier: String?

    var pingIDs: [UUID] {
        get {
            guard !pingIDsString.isEmpty else { return [] }
            return pingIDsString.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
        }
        set {
            pingIDsString = newValue.map(\.uuidString).joined(separator: ",")
        }
    }

    /// O(1) append of one ping reference, keeping `pingCount` in step.
    ///
    /// Going through the `pingIDs` accessor (parse ALL segments, append one,
    /// re-join ALL) per folded ping is quadratic when a dense import batch
    /// lands in one host stay. Appending to the serialized string directly is
    /// equivalent for every writer-produced string (the setter and init are
    /// the only writers, both emit canonical comma-joined `uuidString`s) and
    /// leaves the row CONSISTENT after every single append — no batch-local
    /// state, nothing to flush before a save.
    ///
    /// Malformed segments are preserved untouched. Repairing corrupt
    /// references is the diagnostics repair path's job
    /// (`DebugStayReferenceRepair`), never a silent side effect of an import.
    func appendPingID(_ id: UUID) {
        if pingIDsString.isEmpty {
            pingIDsString = id.uuidString
        } else {
            pingIDsString += "," + id.uuidString
        }
        pingCount += 1
    }

    var category: StayCategory {
        get { StayCategory(rawValue: categoryRaw) ?? .unclassified }
        set {
            categoryRaw = newValue.rawValue
            // Provenance describes a home stamp; it ends with it.
            if newValue != .home { setTemporaryHomeProvenance(nil, revision: nil) }
        }
    }

    /// Writes the provenance pair together: the temporary home that made this
    /// stay home and the coverage revision of the copy that did. A nil id
    /// clears both, since a revision describes a stamp. Unchanged values are
    /// not written, so the row is not dirtied for nothing.
    func setTemporaryHomeProvenance(_ id: UUID?, revision: Int?) {
        let revision = id == nil ? nil : revision
        if temporaryHomeID != id { temporaryHomeID = id }
        if temporaryHomeRevision != revision { temporaryHomeRevision = revision }
    }

    /// Type-safe accessor for `sourceRaw`. Reads via `DataSource.decode` so an
    /// unknown raw value (from a future schema) falls back to `.liveSLC`.
    var source: DataSource {
        get { DataSource.decode(sourceRaw) }
        set { sourceRaw = newValue.rawValue }
    }

    /// Type-safe accessor for `transitFromPreviousRaw`.
    var transitMode: TransitMode? {
        get { transitFromPreviousRaw.flatMap { TransitMode.decode($0) } }
        set { transitFromPreviousRaw = newValue?.rawValue }
    }

    /// Type-safe accessor for `weatherConditionRaw`.
    var weatherCondition: StayWeather.Condition? {
        get { weatherConditionRaw.flatMap { StayWeather.Condition(rawValue: $0) } }
        set { weatherConditionRaw = newValue?.rawValue }
    }

    /// Decoded full weather snapshot from `weatherData` blob.
    var weather: StayWeather? {
        get { weatherData.flatMap { StayWeather.decoded(from: $0) } }
        set { weatherData = newValue?.encoded() }
    }

    var centroid: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: centroidLatitude, longitude: centroidLongitude)
    }

    /// Human-readable duration string, e.g. "45m", "3h 20m", "2d 5h".
    var formattedDuration: String {
        let minutes = durationMinutes
        if minutes < 60 {
            return String(
                localized: "stay.duration.minutes",
                defaultValue: "\(minutes, format: .number.grouping(.never))m",
                comment: "Compact stay duration in minutes."
            )
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours < 24 {
            return remainingMinutes > 0
                ? String(
                    localized: "stay.duration.hours-minutes",
                    defaultValue: "\(hours, format: .number.grouping(.never))h \(remainingMinutes, format: .number.grouping(.never))m",
                    comment: "Compact stay duration in hours and minutes."
                )
                : String(
                    localized: "stay.duration.hours",
                    defaultValue: "\(hours, format: .number.grouping(.never))h",
                    comment: "Compact stay duration in hours."
                )
        }
        let days = hours / 24
        let remainingHours = hours % 24
        return remainingHours > 0
            ? String(
                localized: "stay.duration.days-hours",
                defaultValue: "\(days, format: .number.grouping(.never))d \(remainingHours, format: .number.grouping(.never))h",
                comment: "Compact stay duration in days and hours."
            )
            : String(
                localized: "stay.duration.days",
                defaultValue: "\(days, format: .number.grouping(.never))d",
                comment: "Compact stay duration in days."
            )
    }

    init(
        startTime: Date,
        endTime: Date,
        centroidLatitude: Double,
        centroidLongitude: Double,
        h3IndexRes6: String,
        pingCount: Int,
        distanceFromHomeKm: Double,
        pingIDs: [UUID],
        source: DataSource = .liveSLC,
        timeZoneIdentifier: String? = nil
    ) {
        self.id = UUID()
        self.startTime = startTime
        self.endTime = endTime
        self.durationMinutes = Int(endTime.timeIntervalSince(startTime) / 60)
        self.centroidLatitude = centroidLatitude
        self.centroidLongitude = centroidLongitude
        self.h3IndexRes6 = h3IndexRes6
        self.pingCount = pingCount
        self.distanceFromHomeKm = distanceFromHomeKm
        self.categoryRaw = StayCategory.unclassified.rawValue
        self.userOverridden = false
        self.continuesPreviousTrip = false
        self.pingIDsString = pingIDs.map(\.uuidString).joined(separator: ",")
        self.sourceRaw = source.rawValue
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}

// MARK: - City Deduplication

extension Stay {
    /// Counts distinct metropolitan areas by clustering stay coordinates.
    ///
    /// Two-phase approach: (1) group stays by their H3 res-6 hex to reduce
    /// n stays into k hex-group centroids. (2) build a proximity graph where
    /// hex groups within `thresholdKm` are connected, then count connected
    /// components via union-find. Purely coordinate-based, fully
    /// order-independent, O(n + k^2).
    ///
    /// `nonisolated`: pure function of stored fields (`h3IndexRes6`,
    /// centroid coordinates), called off-main by `StatsAggregator`.
    nonisolated static func deduplicatedCityCount(from stays: [Stay], thresholdKm: Double = 25) -> Int {
        deduplicatedCityCount(from: stays, thresholdKm: thresholdKm, checkCancellation: {})
    }

    nonisolated static func deduplicatedCityCount(
        from stays: [Stay], thresholdKm: Double = 25,
        checkCancellation: () throws -> Void
    ) rethrows -> Int {
        try checkCancellation()
        var accumulator = CityCountAccumulator()
        for stay in stays {
            try checkCancellation()
            accumulator.add(
                h3IndexRes6: stay.h3IndexRes6,
                latitude: stay.centroidLatitude, longitude: stay.centroidLongitude)
        }
        return try accumulator.count(thresholdKm: thresholdKm, checkCancellation: checkCancellation)
    }

    /// Phase 1 of the city count as an incremental value. A caller that cannot
    /// hold every row (the widget extension pages stays through short-lived
    /// contexts) feeds it scalars; `deduplicatedCityCount(from:)` feeds it rows,
    /// so both produce the same number from the same stays.
    nonisolated struct CityCountAccumulator {
        private struct Node {
            let latitude: Double
            let longitude: Double
        }

        // Longitudes accumulate as wrapped deltas from the group's FIRST
        // value: a straight sum averages +179.99° and −179.99° to ~0° — a
        // phantom centroid near Greenwich that corrupts the proximity union
        // and the city count. Identical
        // to the plain mean whenever the group doesn't straddle ±180°.
        private var hexGroups: [String: (sumLat: Double, refLon: Double, sumDeltaLon: Double, count: Int)] = [:]
        private var ungroupedNodes: [Node] = []

        mutating func add(h3IndexRes6 key: String, latitude: Double, longitude: Double) {
            if key.isEmpty {
                ungroupedNodes.append(Node(latitude: latitude, longitude: longitude))
            } else if let existing = hexGroups[key] {
                hexGroups[key] = (existing.sumLat + latitude,
                                  existing.refLon,
                                  existing.sumDeltaLon + GeoMath.wrappedLongitudeDelta(longitude, existing.refLon),
                                  existing.count + 1)
            } else {
                hexGroups[key] = (latitude, longitude, 0, 1)
            }
        }

        func count(thresholdKm: Double = 25) -> Int {
            count(thresholdKm: thresholdKm, checkCancellation: {})
        }

        func count(thresholdKm: Double, checkCancellation: () throws -> Void) rethrows -> Int {
            var nodes: [Node] = hexGroups.values.map { g in
                Node(latitude: g.sumLat / Double(g.count),
                     longitude: GeoMath.normalizedLongitude(g.refLon + g.sumDeltaLon / Double(g.count)))
            }
            nodes.append(contentsOf: ungroupedNodes)

            let n = nodes.count
            if n == 0 { return 0 }

            var parent = Array(0..<n)
            var rank = Array(repeating: 0, count: n)

            func find(_ x: Int) -> Int {
                var x = x
                while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
                return x
            }
            func union(_ a: Int, _ b: Int) {
                let ra = find(a), rb = find(b)
                guard ra != rb else { return }
                if rank[ra] < rank[rb] { parent[ra] = rb }
                else if rank[ra] > rank[rb] { parent[rb] = ra }
                else { parent[rb] = ra; rank[ra] += 1 }
            }

            let thresholdMeters = thresholdKm * 1000
            // **Latitude-band cull.** The geodesic distance
            // between two points is at least their meridian (latitude) separation,
            // and 1° of latitude spans ≥ 110,574 m everywhere on the WGS84
            // ellipsoid — so once two nodes' latitudes alone put them past the
            // threshold, the pair is provably unconnected and the geodesic
            // call can be skipped. With nodes sorted by
            // latitude the inner loop breaks at the band edge, turning the all-
            // pairs O(k²) scan (~80k pairs / 160k allocations at 400 hex groups,
            // re-run on every Stats render) into O(k log k + k·band). Surviving
            // pairs use the IDENTICAL exact check, so the component count — and
            // every existing test fixture — is unchanged.
            let minMetersPerLatDegree = 110_574.0
            let maxLatGap = thresholdMeters / minMetersPerLatDegree
            let order = (0..<n).sorted { nodes[$0].latitude < nodes[$1].latitude }
            // One location per measured node, made on first use, instead of two
            // per pair. Every pair is still measured: `distance(from:)` results
            // depend on earlier calls, so skipping pairs could move an edge case.
            var locations = [CLLocation?](repeating: nil, count: n)
            func location(_ k: Int) -> CLLocation {
                if let made = locations[k] { return made }
                let made = CLLocation(latitude: nodes[k].latitude, longitude: nodes[k].longitude)
                locations[k] = made
                return made
            }
            for oi in 0..<n {
                try checkCancellation()
                let i = order[oi]
                for oj in (oi + 1)..<n {
                    try checkCancellation()
                    let j = order[oj]
                    if nodes[j].latitude - nodes[i].latitude > maxLatGap { break }
                    if location(i).distance(from: location(j)) < thresholdMeters {
                        union(i, j)
                    }
                }
            }

            var roots = Set<Int>()
            for i in 0..<n {
                try checkCancellation()
                roots.insert(find(i))
            }
            return roots.count
        }
    }
}

// MARK: - StayCategory

/// Classification category for a Stay.
///
/// Stored as a raw string in SwiftData for compatibility.
/// Will also be used as a `@Generable` enum for Foundation Models output.
nonisolated enum StayCategory: String, Codable, CaseIterable, Identifiable {
    case home
    case routine
    case destination
    case transit
    case unclassified

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .home:
            String(localized: "stay.category.home", defaultValue: "Home", comment: "Stay category name.")
        case .routine:
            String(localized: "stay.category.routine", defaultValue: "Routine", comment: "Stay category name.")
        case .destination:
            String(localized: "stay.category.destination", defaultValue: "Destination", comment: "Stay category name.")
        case .transit:
            String(localized: "stay.category.transit", defaultValue: "Transit", comment: "Stay category name.")
        case .unclassified:
            String(localized: "stay.category.unclassified", defaultValue: "Unclassified", comment: "Stay category name.")
        }
    }
}

// MARK: - Shared fetch predicates (app + widget)

extension Stay {

    /// The "counts as visited" predicate: home + routine + destination — the
    /// three categories that represent the user having actually BEEN somewhere
    /// (transit legs and unclassified residue don't paint stats). Consumed by
    /// the widget TimelineProviders (TravelStatsProvider, StatsAccessoryProvider)
    /// and pinned by `WidgetStayPredicateTests`; a single factory so the app,
    /// the widget, and the tests can never drift apart on what "visited" means.
    /// The rawValues are captured as locals because `#Predicate` requires
    /// constant captures, and capturing the enum (not a string literal) means a
    /// case rename cannot silently diverge from the stored tokens here.
    nonisolated static func visitedCategoriesPredicate() -> Predicate<Stay> {
        let home = StayCategory.home.rawValue
        let routine = StayCategory.routine.rawValue
        let destination = StayCategory.destination.rawValue
        return #Predicate<Stay> {
            $0.categoryRaw == home || $0.categoryRaw == routine || $0.categoryRaw == destination
        }
    }

    /// Transit-category stays — the input to `HexVisibility.hiddenHexes`.
    nonisolated static func transitCategoryPredicate() -> Predicate<Stay> {
        let transit = StayCategory.transit.rawValue
        return #Predicate<Stay> { $0.categoryRaw == transit }
    }

    /// Hands `body` the matching rows one page at a time, each page fetched by
    /// its own short-lived context, so the caller never holds more than
    /// `pageSize` materialized rows. For the widget extension: 10,000 visited
    /// stays fetched at once measured about 23 MB against its ~30 MB budget,
    /// paged about 1.4 MB (0.4 s; 40,000 stays take about 3 s because every
    /// offset page re-sorts). `body` must copy the scalars it needs and keep no row.
    /// A row inserted or deleted by the app between pages can shift the window
    /// by one row; the aggregates built on this are sets and per-hex means, so
    /// the next timeline reload corrects it. A failed page throws; callers
    /// must discard the partial aggregate. `beforePage` runs before each page
    /// fetch (a test checkpoint).
    nonisolated static func forEachPage(
        matching predicate: Predicate<Stay>,
        propertiesToFetch: [PartialKeyPath<Stay>],
        in container: ModelContainer,
        pageSize: Int = 2_000,
        beforePage: () throws -> Void = {},
        _ body: ([Stay]) -> Void
    ) throws {
        var offset = 0
        while true {
            try beforePage()
            let fetched = try autoreleasepool {
                let context = ModelContext(container)
                context.autosaveEnabled = false
                var descriptor = FetchDescriptor<Stay>(
                    predicate: predicate,
                    sortBy: [SortDescriptor(\.startTime), SortDescriptor(\.id)])
                descriptor.propertiesToFetch = propertiesToFetch
                descriptor.fetchOffset = offset
                descriptor.fetchLimit = pageSize
                let page = try context.fetch(descriptor)
                body(page)
                return page.count
            }
            offset += fetched
            if fetched < pageSize { return }
        }
    }
}

// MARK: - Widget store reads (app + widget)

/// The required reads behind the widget timelines and the Next Trip intent.
/// A failed read is not an empty store: providers show a redacted placeholder
/// on the short retry cadence instead of zeros on the regular one.
nonisolated enum WidgetStoreRead: Sendable, Equatable {
    case visitedPage, completedTripCount, transitPage, hexVisitCount
    case ongoingTrip, completedTrip
    case temporaryHomes, latestHomeStay
    case plannedTrips, homes, ongoingTrips

    #if DEBUG
    @TaskLocal static var failureForTesting: (@Sendable (WidgetStoreRead) throws -> Void)?
    #endif

    /// Test checkpoint immediately before a required read; a no-op in release.
    static func check(_ read: WidgetStoreRead) throws {
        #if DEBUG
        try failureForTesting?(read)
        #endif
    }
}

extension Stay {

    /// The Travel Stats widget's four counters.
    nonisolated struct WidgetTravelStats: Sendable, Equatable {
        /// Tracked countries only; the provider unions the remembered ones.
        let countryCodes: Set<String>
        let cityCount: Int
        let tripCount: Int
        let hexCount: Int
    }

    /// Paged, scalar-only reads: the widget extension runs under a tight
    /// (~30 MB) budget, and visited stays include every home and routine
    /// dwell. Fetching them in one array measured about 23 MB at 10,000
    /// stays (jetsam: a blank or stale tile); paging keeps
    /// only the aggregates. Throws when any read fails, including a later
    /// page, so no partial count is ever returned.
    nonisolated static func widgetTravelStats(
        in container: ModelContainer, pageSize: Int = 2_000
    ) throws -> WidgetTravelStats {
        var countryCodes = Set<String>()
        var realHexes = Set<String>()
        var cities = CityCountAccumulator()
        try forEachPage(
            matching: visitedCategoriesPredicate(),
            propertiesToFetch: [\.isoCountryCode, \.h3IndexRes6, \.centroidLatitude, \.centroidLongitude],
            in: container,
            pageSize: pageSize,
            beforePage: { try WidgetStoreRead.check(.visitedPage) }
        ) { page in
            for stay in page {
                if let code = stay.isoCountryCode { countryCodes.insert(code) }
                if !stay.h3IndexRes6.isEmpty { realHexes.insert(stay.h3IndexRes6) }
                cities.add(
                    h3IndexRes6: stay.h3IndexRes6,
                    latitude: stay.centroidLatitude, longitude: stay.centroidLongitude)
            }
        }

        let context = ModelContext(container)
        context.autosaveEnabled = false
        try WidgetStoreRead.check(.completedTripCount)
        let tripCount = try context.fetchCount(FetchDescriptor<Trip>(predicate: Trip.completedPredicate()))

        // Apply the SAME HexVisibility hide rule the app's Stats/Map use, so the
        // widget can't report a larger "Hexes" number than the app for anyone
        // who has ever flown (the count "can't drift" invariant).
        let flightRaw = TransitMode.flight.rawValue
        var transit: [HexVisibility.TransitStay] = []
        try forEachPage(
            matching: transitCategoryPredicate(),
            propertiesToFetch: [\.h3IndexRes6, \.transitFromPreviousRaw, \.isAirport],
            in: container,
            pageSize: pageSize,
            beforePage: { try WidgetStoreRead.check(.transitPage) }
        ) { page in
            for stay in page {
                transit.append(HexVisibility.TransitStay(
                    h3Index: stay.h3IndexRes6,
                    isFlight: stay.transitFromPreviousRaw == flightRaw,
                    isAirport: stay.isAirport
                ))
            }
        }

        let hidden = HexVisibility.hiddenHexes(transit: transit, realHexes: realHexes)
        // Paged and `h3Index` only: a long history holds tens of thousands of
        // HexVisit rows and this extension's budget is ~30 MB. Same number as
        // `HexVisibility.isVisible` with `isRenderable: { _ in true }`: the
        // widget target doesn't link H3, so it can't apply the drop-from-both
        // renderability arm. Accepted — it only diverges
        // for corrupt rows every write path already validates against.
        let hexCount = try HexVisibility.visibleHexVisitCount(
            hidden: hidden, in: container, pageSize: pageSize,
            beforeCount: { try WidgetStoreRead.check(.hexVisitCount) })

        return WidgetTravelStats(
            countryCodes: countryCodes,
            cityCount: cities.count(),
            tripCount: tripCount,
            hexCount: hexCount
        )
    }

    /// Tracked visited-country codes for the Travel Counter widget, paged and
    /// `isoCountryCode` only for the same memory budget. Throws on any failed
    /// page instead of returning a partial set that would read as the
    /// remembered countries alone.
    nonisolated static func widgetVisitedCountryCodes(
        in container: ModelContainer, pageSize: Int = 2_000
    ) throws -> Set<String> {
        var countryCodes = Set<String>()
        try forEachPage(
            matching: visitedCategoriesPredicate(),
            propertiesToFetch: [\.isoCountryCode],
            in: container,
            pageSize: pageSize,
            beforePage: { try WidgetStoreRead.check(.visitedPage) }
        ) { page in
            for stay in page {
                if let code = stay.isoCountryCode { countryCodes.insert(code) }
            }
        }
        return countryCodes
    }
}
