//
//  StatsAggregator.swift
//  TravelLog
//

import Foundation
import SwiftData
import CoreLocation
import os

/// A country row in the Stats "Countries" card: seeded from visited
/// stays, trip counts layered on from completed trips' `countryCodes`.
/// Codable because it rides in the persisted `StatsSnapshotStore` snapshot.
nonisolated struct CountryStat: Sendable, Equatable, Codable {
    let code: String
    let name: String
    var tripCount: Int
    var isHome: Bool
    /// Distinct calendar days with a trip's destination stay in this
    /// country. Optional for `StatsSnapshotStore` forward-compat (a
    /// pre-field snapshot decodes with `nil`); nil or 0 hides the caption.
    var days: Int? = nil
    /// True for the country of a temporary home, whatever its dates, when it
    /// is not a home country. Optional for the same snapshot rule.
    var isTemporaryHome: Bool? = nil
    /// The Gregorian (UTC) year of the country's earliest visited stay, the
    /// expanded Passport's "first in" year. Optional for the same snapshot rule.
    var firstYear: Int? = nil
}

/// Off-main builder of every aggregate the Stats page displays.
///
/// `load` owns a detached worker and forwards caller cancellation. The
/// worker fetches, reduces and discards managed objects on its own context;
/// only a complete Sendable snapshot returns to the view.
///
/// Each detached compute owns its ModelContext and models; only Sendable aggregates cross back.
/// Read stored fields or explicitly nonisolated pure helpers because other computed properties default to MainActor.
nonisolated enum StatsAggregator {

    /// One "top country by hexes" row for the Exploration card.
    struct HexCountry: Sendable, Equatable, Codable {
        let code: String
        let name: String?
        let count: Int
    }

    /// The "Last Trip" highlight. A named struct (not a tuple) so the
    /// aggregate snapshot can be `Codable` for `StatsSnapshotStore`.
    struct LastTrip: Sendable, Equatable, Codable {
        let name: String
        let date: Date
        /// The trip the record tile opens. Optional for `StatsSnapshotStore`
        /// forward-compat: a pre-field snapshot decodes with `nil`.
        var tripID: UUID? = nil
        /// `Trip.durationDays` of the trip, nil when unknown. Optional for the
        /// same snapshot rule.
        var days: Int? = nil
        /// When the trip ended (`Trip.endDate`). Optional for the same rule.
        var endDate: Date? = nil
    }

    /// The hexes first explored in one Gregorian label year: the cells whose
    /// earliest `HexVisit` falls in it, among the visible cells `totalHexes`
    /// counts.
    struct HexYear: Sendable, Equatable, Codable {
        let year: Int
        let count: Int
    }

    /// The countries first recorded in one Gregorian (UTC) year, by
    /// Wrapped's new-country rule (`firstRecordedCountries`). Sorted codes.
    struct FirstRecordedYear: Sendable, Equatable, Codable {
        let year: Int
        let codes: [String]
    }

    /// One passport stamp: a country's first entry in a Gregorian label year,
    /// from the trip-member destination stays.
    struct StampEntry: Sendable, Equatable, Codable {
        let code: String
        /// The entry's civil date label (UTC midnight, `TravelDays` encoding).
        let day: Date
        /// The entry belongs to a trip still in progress. Optional per the
        /// snapshot rule; nil reads as false.
        var isOngoing: Bool?
    }

    /// One stamp page: the year's stamps in entry order.
    struct StampYear: Sendable, Equatable, Codable {
        let year: Int
        let stamps: [StampEntry]
    }

    /// One country's travel days within a year.
    struct CountryDays: Sendable, Equatable, Codable {
        let code: String
        let days: Int
    }

    /// A destination stay as the stamp pages read it.
    struct StampVisit: Sendable {
        let id: UUID
        let code: String
        let startTime: Date
        let timeZoneIdentifier: String?
        let tripID: UUID?
    }

    /// The trip-length buckets, by inclusive days: 1 to 3, 4 to 7, 8 to 14
    /// and 15 or more. The upper bound of each bucket but the last.
    static let tripLengthBucketUpperBounds = [3, 7, 14]

    /// One Gregorian label year of the "By Year" card. `trips` and `countries`
    /// count completed trips by their first date label's year, and
    /// the union of those trips' `countryCodes`; `days` is the distinct
    /// travel-day set bucketed by year, so an ongoing trip's elapsed days
    /// already show while its trip and countries land on completion.
    struct YearStat: Sendable, Equatable, Codable, Identifiable {
        let year: Int
        var trips = 0
        var days = 0
        var countries = 0
        var id: Int { year }
    }

    /// Persist a Sendable snapshot for cold-launch display while fresh aggregates compute.
    struct Aggregates: Sendable, Codable {
        /// Fetch failure marks degraded data, distinct from an empty store. Optional for old snapshot compatibility; nil is healthy.
        var computeDegraded: Bool?
        var totalPings = 0
        var totalStays = 0
        var totalHexes = 0
        var totalTrips = 0
        var trackingSince: Date?
        var newHexesThisYear = 0
        var topHexCountries: [HexCountry] = []
        var flightCount = 0
        var onThisDayGroups: [OnThisDayYearGroup] = []
        var uniqueCountries: Set<String> = []
        var countryStats: [CountryStat] = []
        var lastTrip: LastTrip?
        var passportData = PassportData()
        /// Collections are computed in the same off-main pass.
        var collections = CollectionsAggregator.Collections()
        /// Active-home countries and explored-hex counts support multiple homes.
        /// Optional fields preserve decoding of older StatsSnapshotStore snapshots.
        var homeHexCountries: [HexCountry]?
        /// Distinct calendar days touched by trips (ongoing count to now).
        var travelDaysThisYear: Int?
        var travelDaysTotal: Int?
        /// Ascending by year; every year with a trip start or a travel day.
        /// Optional per the snapshot forward-compat rule, like the trio above.
        var yearStats: [YearStat]?
        /// Month of the year (1…12) holding the most travel days across all
        /// years, and that count. Ties break on the earlier month.
        var favoriteMonth: Int?
        var favoriteMonthDays: Int?
        /// Travel days plus the days lived at temporary homes
        /// (`TemporaryHomeLedger`). Nil when there is no temporary home, and
        /// Optional per the snapshot rule; the travel counters above stay trip-only.
        var awayDaysTotal: Int?
        var awayDaysThisYear: Int?
        /// Days at temporary homes that no trip covers.
        var stayingDaysTotal: Int?
        /// Travel days per Gregorian month, January first, all years pooled:
        /// the favourite month's bins, trip-only like it. Optional per the
        /// snapshot rule, like every field below.
        var monthTravelDays: [Int]?
        /// Completed trips (distinct ids) per `tripLengthBucketUpperBounds`
        /// bucket, shortest first; trips of unknown length are left out.
        var tripLengthBuckets: [Int]?
        /// Countries first recorded per year, ascending; years with none are
        /// absent. Tracked data only: remembered countries carry no date.
        var firstRecordedCountries: [FirstRecordedYear]?
        /// New hexes per Gregorian label year, ascending; years with none are
        /// absent. The current year's entry matches `newHexesThisYear` unless
        /// a first visit is dated in a later year.
        var newHexesByYear: [HexYear]?
        /// Travel days per Gregorian month of the current label year, January
        /// first; trip-only, like `monthTravelDays`.
        var monthTravelDaysThisYear: [Int]?
        /// Deduplicated cities (25 km) among the trip-member destination
        /// stays that start in the current year.
        var citiesThisYear: Int?
        /// Trip-member destination days per country in the current label
        /// year, most days first; countries without a day are absent.
        var countryDaysThisYear: [CountryDays]?
        /// The expanded Passport's stamp pages, ascending by year.
        var stampYears: [StampYear]?
        /// The stamp pages' first-ever marks: each first-recorded country on
        /// the page of the stay that first recorded it, ascending by stamp
        /// year (`firstEverStampYears`). Nil on older snapshots.
        var firstEverStampYears: [FirstRecordedYear]?
    }

    /// Every required store read behind the Stats page and the Siri
    /// summaries. A DEBUG hook can fail one by label; the compute marks a
    /// failed read degraded and the summaries throw it.
    enum Read: String, Sendable, CaseIterable {
        // `compute`
        case visited, transit, trips, hexVisits, homes
        case pingCount, stayCount, flightCount, trackingSince, unclassified
        case temporaryHomes
        // `compute`, only when a temporary home exists: the ledger's
        // projected adapter, which makes its own reads (`TemporaryHomeLedger.Read`)
        case awayLedger
        // `passportSummary`
        case lifetimeVisited, lifetimeCompletedTrips, lifetimeFlights, lifetimeTravelDays
        // container `yearSummary`
        case yearBoundaries, yearCompletedTrips, yearTravelDays, yearDestinations, yearFlights

        static let computeReads: [Read] = [
            .visited, .transit, .trips, .hexVisits, .homes,
            .pingCount, .stayCount, .flightCount, .trackingSince, .unclassified,
            .temporaryHomes,
        ]
        static let lifetimeReads: [Read] = [
            .lifetimeVisited, .lifetimeCompletedTrips, .lifetimeFlights, .lifetimeTravelDays,
        ]
        static let yearReads: [Read] = [
            .yearBoundaries, .yearCompletedTrips, .yearTravelDays, .yearDestinations, .yearFlights,
        ]
    }

    #if DEBUG
    /// Fails the named read. `load` and the Siri loader re-install it on their
    /// detached workers, which do not inherit task-locals.
    @TaskLocal static var readFailureForTesting: (@Sendable (Read) throws -> Void)?
    #endif

    /// Test checkpoint immediately before a required read; a no-op in release.
    static func checkRead(_ read: Read) throws {
        #if DEBUG
        try readFailureForTesting?(read)
        #endif
    }

    // MARK: - Fetch + reduce

    /// Fetch the page's inputs on a fresh (caller-thread) context and reduce
    /// them. Reads committed state only — `StatsView` flushes any pending
    /// main-context changes before dispatching, so the pass can't read past
    /// an unsaved edit.
    /// Project stored Stay fields used by Stats, Collections, On This Day, and city counting.
    /// Add backing fields here when adding reads (`CollectionsAggregator.StayRow` copies them);
    /// missing fields lazy-load with a per-row roundtrip.
    /// Keep heavy weather/ping payloads out. The to-one trip reference is projected because destination
    /// reads test trip membership per stay; to-many relationships stay lazy. StatsProjectionParityTests checks parity.
    nonisolated static var aggregateStayProperties: [PartialKeyPath<Stay>] { [
        \.id, \.startTime, \.endTime, \.timeZoneIdentifier, \.durationMinutes,
        \.centroidLatitude, \.centroidLongitude,
        \.locality, \.administrativeArea, \.country, \.isoCountryCode,
        \.metroName, \.islandName,
        \.avgTemperatureC, \.weatherConditionRaw,
        \.transitFromPreviousRaw, \.distanceFromPreviousKm,
        \.isAirport, \.h3IndexRes6, \.distanceFromHomeKm, \.categoryRaw,
        \.temporaryHomeID, \.pingCount, \.sourceRaw,
        \.trip,
    ] }

    /// Unclassified stays supply only predecessor place/geometry data to Collections
    /// (`CollectionsAggregator.Endpoint` reads exactly these), and their start
    /// and country to the first-recorded countries.
    nonisolated static var predecessorStayProperties: [PartialKeyPath<Stay>] { [
        \.id, \.startTime, \.endTime, \.centroidLatitude, \.centroidLongitude,
        \.isoCountryCode, \.metroName, \.islandName,
        \.locality, \.administrativeArea, \.country, \.isAirport,
        \.timeZoneIdentifier, \.categoryRaw, \.distanceFromHomeKm,
        \.pingCount, \.sourceRaw,
    ] }

    /// Own the worker so a superseded view refresh also stops its work.
    /// `importPingRevision`: `StoreChangeTracker.revision(for: importPingChanges)`
    /// read before the call, so an unchanged import-ping surplus is reused.
    static func load(
        container: ModelContainer,
        now: Date = .now,
        calendar: Calendar = .current,
        importPingRevision: Int? = nil,
        checkCancellation: @escaping @Sendable () throws -> Void = {}
    ) async throws -> Aggregates {
        try Task.checkCancellation()
        #if DEBUG
        let readFailure = readFailureForTesting
        #endif
        let worker = Task.detached(priority: .userInitiated) {
            #if DEBUG
            return try $readFailureForTesting.withValue(readFailure) {
                try compute(container: container, now: now, calendar: calendar,
                            importPingRevision: importPingRevision) {
                    try Task.checkCancellation()
                    try checkCancellation()
                    try Task.checkCancellation()
                }
            }
            #else
            return try compute(container: container, now: now, calendar: calendar,
                               importPingRevision: importPingRevision) {
                try Task.checkCancellation()
                try checkCancellation()
                try Task.checkCancellation()
            }
            #endif
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
        }
    }

    static func compute(
        container: ModelContainer,
        now: Date = .now,
        usingProjection: Bool = true,
        calendar: Calendar = .current,
        importPingRevision: Int? = nil,
        checkCancellation: () throws -> Void = Task.checkCancellation
    ) throws -> Aggregates {
        try checkCancellation()
        let context = ModelContext(container)
        context.autosaveEnabled = false

        // Empty stores must render; degraded fetches must never reach the page,
        // the share card or a cold-launch snapshot.
        var degraded = false
        func fetching<T>(_ read: Read, _ body: () throws -> [T]) throws -> [T] {
            try checkCancellation()
            let rows: [T]
            do {
                try checkRead(read)
                rows = try body()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                degraded = true
                rows = []
            }
            // Outside the degraded-error catch: cancellation is never data.
            try checkCancellation()
            return rows
        }
        func counting(_ read: Read, _ body: () throws -> Int) throws -> Int {
            try checkCancellation()
            let count: Int
            do {
                try checkRead(read)
                count = try body()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                degraded = true
                count = 0
            }
            try checkCancellation()
            return count
        }

        // Temporary homes add the days lived at them to Passport's days away
        // and flag their country rows. Everything past this one fetch is
        // guarded on a row existing.
        let temporaryHomeRows = try fetching(.temporaryHomes) { try context.fetch(FetchDescriptor<TemporaryHome>()) }
        let temporaryHomes = HomeAnchors.collapsingTwins(temporaryHomeRows).map { HomeAnchor($0) }
        let hasTemporaryHome = !temporaryHomes.isEmpty
        let temporaryHomeIDs = Set(temporaryHomes.map(\.id))

        // `usingProjection: false` is the full-fetch reference lane for the
        // `StatsProjectionParityTests` oracle — never used in production.
        var visitedDescriptor = FetchDescriptor<Stay>(
            predicate: #Predicate {
                $0.categoryRaw == "home" || $0.categoryRaw == "routine" || $0.categoryRaw == "destination"
            }
        )
        if usingProjection { visitedDescriptor.propertiesToFetch = aggregateStayProperties }
        let visitedStays = try fetching(.visited) { try context.fetch(visitedDescriptor) }
        var transitDescriptor = FetchDescriptor<Stay>(
            predicate: #Predicate { $0.categoryRaw == "transit" }
        )
        if usingProjection { transitDescriptor.propertiesToFetch = aggregateStayProperties }
        let transitStays = try fetching(.transit) { try context.fetch(transitDescriptor) }
        let trips = try fetching(.trips) { try context.fetch(FetchDescriptor<Trip>()) }
        let hexVisits = try fetching(.hexVisits) { try context.fetch(FetchDescriptor<HexVisit>()) }
        let activeHomes = try fetching(.homes) { try context.fetch(FetchDescriptor<Home>(
            predicate: #Predicate { $0.endedAt == nil }
        )) }
        var anchors: [HomeAnchor] = []
        var awayLedger: TemporaryHomeLedger.Result?
        // The ledger's trip spans, which the reduction reuses.
        var tripSpans: [TravelDays.Span]?
        if hasTemporaryHome {
            // Who owns a home stay depends on ended Homes too, which the
            // active-home fetch above leaves out.
            let homes = try fetching(.homes) { try context.fetch(FetchDescriptor<Home>()) }
            anchors = homes.map { HomeAnchor($0) } + temporaryHomes
            // The adapter Siri and Wrapped read, over every stay whatever its
            // category, so all three report the same days. A failed read
            // inside it degrades this compute like any other.
            awayLedger = try fetching(.awayLedger) { () throws -> [TemporaryHomeLedger.Result] in
                let spans = try TravelDays.spans(trips: trips, checkCancellation: checkCancellation)
                tripSpans = spans
                return [try TemporaryHomeLedger.result(
                    travelling: TravelDays.labels(spans: spans, now: now, fallbackZone: calendar.timeZone,
                                                  checkCancellation: checkCancellation),
                    container: container, now: now, fallbackZone: calendar.timeZone,
                    checkCancellation: checkCancellation)]
            }.first
        }

        // Farthest from home measures from the real Homes once the store holds
        // or held a temporary home: a removed one leaves trips stamped from it.
        var farthestAnchors: [HomeAnchor]?
        if !hasTemporaryHome, !temporaryHomeRows.isEmpty {
            farthestAnchors = try fetching(.homes) { try context.fetch(FetchDescriptor<Home>()) }
                .map { HomeAnchor($0) }
        }

        let totalPings = try counting(.pingCount) {
            try context.fetchCount(FetchDescriptor<LocationPing>()) - importPingTwinSurplus(
                in: context, container: container, revision: importPingRevision,
                checkCancellation: checkCancellation)
        }
        let totalStays = try counting(.stayCount) { try context.fetchCount(FetchDescriptor<Stay>()) }

        // Flights count every stay (any category) whose leg-in was inferred
        // a flight — a COUNT with predicate, no row materialization.
        let flightRaw = TransitMode.flight.rawValue
        let flightCount = try counting(.flightCount) { try context.fetchCount(FetchDescriptor<Stay>(
            predicate: #Predicate { $0.transitFromPreviousRaw == flightRaw }
        )) }

        var firstPingDescriptor = FetchDescriptor<LocationPing>(
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        firstPingDescriptor.fetchLimit = 1
        let trackingSince = try fetching(.trackingSince) { try context.fetch(firstPingDescriptor) }.first?.timestamp

        // Unclassified rows participate only in the Collections predecessor walk.
        var unclassifiedDescriptor = FetchDescriptor<Stay>(
            predicate: #Predicate { $0.categoryRaw == "unclassified" }
        )
        if usingProjection { unclassifiedDescriptor.propertiesToFetch = predecessorStayProperties }
        let unclassifiedStays = try fetching(.unclassified) { try context.fetch(unclassifiedDescriptor) }

        // Each row's fields are read once; every reduction below works on values.
        // Copies check cancellation per row, as the model-read passes did.
        try checkCancellation()
        let visitedRows = try visitedStays.map {
            try checkCancellation()
            return CollectionsAggregator.StayRow($0)
        }
        var computed = try aggregate(
            visited: visitedRows,
            transit: transitStays.map {
                try checkCancellation()
                return CollectionsAggregator.StayRow($0)
            },
            unclassified: unclassifiedStays.map {
                try checkCancellation()
                return CollectionsAggregator.Endpoint($0)
            },
            tripSpans: tripSpans,
            trips: trips,
            hexVisits: hexVisits,
            totalPings: totalPings,
            totalStays: totalStays,
            flightCount: flightCount,
            trackingSince: trackingSince,
            homeCountryCodes: try resolveHomeCountryCodes(
                homes: activeHomes.map {
                    ActiveHomeGeo(
                        isoCountryCode: $0.isoCountryCode,
                        latitude: $0.latitude, longitude: $0.longitude,
                        radiusKm: $0.radiusKm
                    )
                },
                homeStays: visitedRows
                    .filter { stay in
                        guard stay.categoryRaw == StayCategory.home.rawValue else { return false }
                        // A temporary home's stays never resolve the real Home's
                        // country: only a stay its writer recorded as the real
                        // Home's does, never the nearest centre.
                        return HomeAnchors.recordedOwner(
                            temporaryHomeID: stay.temporaryHomeID,
                            knownTemporaryHomeIDs: temporaryHomeIDs) == .realHome
                    }
                    .map { ($0.isoCountryCode, $0.centroidLatitude, $0.centroidLongitude) },
                checkCancellation: checkCancellation
            ),
            anchors: anchors,
            farthestAnchors: farthestAnchors,
            awayLedger: awayLedger,
            now: now,
            calendar: calendar,
            checkCancellation: checkCancellation
        )
        // Fetch ownership makes this the place to mark degradation; healthy snapshots omit the optional field.
        try checkCancellation()
        computed.computeDegraded = degraded ? true : nil
        return computed
    }

    /// One active Home's geometry + (possibly missing) country, for
    /// `resolveHomeCountryCodes`.
    struct ActiveHomeGeo: Sendable {
        let isoCountryCode: String?
        let latitude: Double
        let longitude: Double
        let radiusKm: Double
    }

    /// Extra physical rows among photo, Timeline and GPX pings that share a
    /// UUID: two restores of one backup keep equal-rank twins
    /// (`PhotoImportPingDeduplicator`), and Passport counts each ping once.
    /// Reads projected ids in batches, checking cancellation as it goes.
    static func importPingTwinSurplus(
        in context: ModelContext, checkCancellation: () throws -> Void = {}
    ) throws -> Int {
        var descriptor = FetchDescriptor<LocationPing>(predicate: #Predicate {
            $0.sourceRaw == "photoImport" || $0.sourceRaw == "timelineImport"
                || $0.sourceRaw == "gpxImport"
        })
        descriptor.propertiesToFetch = [\.id]
        var seen = Set<UUID>()
        var surplus = 0
        var visited = 0
        try checkCancellation()
        try context.enumerate(descriptor, batchSize: importPingBatchSize) { ping in
            visited += 1
            if visited % importPingBatchSize == 0 { try checkCancellation() }
            if !seen.insert(ping.id).inserted { surplus += 1 }
        }
        return surplus
    }

    private static let importPingBatchSize = 2_000

    /// The store changes that can move the import-ping surplus. Live pings
    /// are never import pings, but every writer that inserts or deletes
    /// import pings declares `.locationPing` or `.stay` (or `.all`).
    static let importPingChanges: StoreChange = [.locationPing, .stay]

    /// The last surplus this process counted: its container and the
    /// `StoreChangeTracker.revision(for: importPingChanges)` it was read at.
    private static let importPingSurplusCache =
        OSAllocatedUnfairLock<(container: ObjectIdentifier, revision: Int, surplus: Int)?>(initialState: nil)

    /// `importPingTwinSurplus`, reused while `revision` (captured before the
    /// compute) has not moved: a Stats refresh for a trip edit, a day change
    /// or a reappearance no longer scans every import ping again. A store
    /// writer bumps the tracker after it saves, so a count read at a revision
    /// never reflects less than that revision's store. Nil never caches.
    static func importPingTwinSurplus(
        in context: ModelContext, container: ModelContainer, revision: Int?,
        checkCancellation: () throws -> Void
    ) throws -> Int {
        let key = ObjectIdentifier(container)
        if let revision, let cached = importPingSurplusCache.withLock({ $0 }),
           cached.container == key, cached.revision == revision {
            return cached.surplus
        }
        let surplus = try importPingTwinSurplus(in: context, checkCancellation: checkCancellation)
        if let revision {
            importPingSurplusCache.withLock { $0 = (key, revision, surplus) }
        }
        return surplus
    }

    /// Active-home country codes drive present-tense home badges and exploration pins.
    /// Prefer the stamped ISO; otherwise use the most frequent home-stay code inside its ring.
    /// Break ties lexicographically so devices agree and ungeocoded homes retain their country.
    static func resolveHomeCountryCodes(
        homes: [ActiveHomeGeo],
        homeStays: [(iso: String?, latitude: Double, longitude: Double)]
    ) -> Set<String> {
        resolveHomeCountryCodes(homes: homes, homeStays: homeStays, checkCancellation: {})
    }

    static func resolveHomeCountryCodes(
        homes: [ActiveHomeGeo],
        homeStays: [(iso: String?, latitude: Double, longitude: Double)],
        checkCancellation: () throws -> Void
    ) rethrows -> Set<String> {
        try checkCancellation()
        var codes = Set<String>()
        for home in homes {
            try checkCancellation()
            if let iso = home.isoCountryCode {
                codes.insert(iso)
                continue
            }
            let homeLocation = CLLocation(latitude: home.latitude, longitude: home.longitude)
            var counts: [String: Int] = [:]
            for stay in homeStays {
                try checkCancellation()
                guard let iso = stay.iso else { continue }
                let distKm = CLLocation(latitude: stay.latitude, longitude: stay.longitude)
                    .distance(from: homeLocation) / 1000.0
                if distKm <= home.radiusKm {
                    counts[iso, default: 0] += 1
                }
            }
            if let winner = counts.max(by: { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                return lhs.key > rhs.key
            }) {
                codes.insert(winner.key)
            }
        }
        return codes
    }

    /// Pure reducer test seam over already-fetched rows.
    static func aggregate(
        visitedStays: [Stay], transitStays: [Stay], unclassifiedStays: [Stay] = [],
        trips: [Trip], hexVisits: [HexVisit], totalPings: Int, totalStays: Int,
        flightCount: Int, trackingSince: Date?, homeCountryCodes: Set<String> = [],
        anchors: [HomeAnchor] = [],
        now: Date = .now, calendar: Calendar = .current
    ) -> Aggregates {
        aggregate(visitedStays: visitedStays, transitStays: transitStays,
                  unclassifiedStays: unclassifiedStays, trips: trips, hexVisits: hexVisits,
                  totalPings: totalPings, totalStays: totalStays, flightCount: flightCount,
                  trackingSince: trackingSince, homeCountryCodes: homeCountryCodes,
                  anchors: anchors,
                  now: now, calendar: calendar, checkCancellation: {})
    }

    static func aggregate(
        visitedStays: [Stay],
        transitStays: [Stay],
        unclassifiedStays: [Stay] = [],
        trips: [Trip],
        hexVisits: [HexVisit],
        totalPings: Int,
        totalStays: Int,
        flightCount: Int,
        trackingSince: Date?,
        homeCountryCodes: Set<String> = [],
        // Every Home and temporary home, and the days-away ledger `compute`
        // read for them. Empty and nil unless a temporary home exists.
        anchors: [HomeAnchor] = [],
        // The Homes Farthest from home measures from: `anchors` when nil, the
        // real Homes too once every temporary home was removed.
        farthestAnchors: [HomeAnchor]? = nil,
        // When supplied, this ledger must use these trips, `now` and the
        // calendar's fallback zone; its travelling labels are reused below.
        awayLedger: TemporaryHomeLedger.Result? = nil,
        now: Date = .now,
        calendar: Calendar = .current,
        checkCancellation: () throws -> Void
    ) rethrows -> Aggregates {
        try checkCancellation()
        return try aggregate(
            visited: visitedStays.map {
                try checkCancellation()
                return CollectionsAggregator.StayRow($0)
            },
            transit: transitStays.map {
                try checkCancellation()
                return CollectionsAggregator.StayRow($0)
            },
            unclassified: unclassifiedStays.map {
                try checkCancellation()
                return CollectionsAggregator.Endpoint($0)
            },
            tripSpans: nil,
            trips: trips, hexVisits: hexVisits,
            totalPings: totalPings, totalStays: totalStays, flightCount: flightCount,
            trackingSince: trackingSince, homeCountryCodes: homeCountryCodes,
            anchors: anchors, farthestAnchors: farthestAnchors, awayLedger: awayLedger,
            now: now, calendar: calendar, checkCancellation: checkCancellation)
    }

    /// The reduction over fields copied once per stay. `tripSpans`, when
    /// supplied, are `TravelDays.spans(trips:)` of these trips.
    private static func aggregate(
        visited visitedStays: [CollectionsAggregator.StayRow],
        transit transitStays: [CollectionsAggregator.StayRow],
        unclassified unclassifiedStays: [CollectionsAggregator.Endpoint],
        tripSpans: [TravelDays.Span]?,
        trips: [Trip],
        hexVisits: [HexVisit],
        totalPings: Int,
        totalStays: Int,
        flightCount: Int,
        trackingSince: Date?,
        homeCountryCodes: Set<String>,
        anchors: [HomeAnchor],
        farthestAnchors: [HomeAnchor]?,
        awayLedger: TemporaryHomeLedger.Result?,
        now: Date,
        calendar: Calendar,
        checkCancellation: () throws -> Void
    ) rethrows -> Aggregates {
        try checkCancellation()
        var result = Aggregates()
        result.totalPings = totalPings
        result.totalStays = totalStays
        result.totalTrips = trips.count
        result.flightCount = flightCount
        result.trackingSince = trackingSince

        // Strict subset of visitedStays — partition in memory instead of
        // materializing every destination row a second time.
        let destinationStays = try visitedStays.filter {
            try checkCancellation()
            return $0.categoryRaw == "destination"
        }
        let completedTrips = try trips.filter {
            try checkCancellation()
            return $0.isComplete
        }

        // Use the SAME HexVisibility row filter as the map; aerial-only transit hexes are hidden.
        // Never subtract hidden.count: centroid hexes may have no HexVisit row.
        let realHexes = Set(try visitedStays.compactMap {
            try checkCancellation()
            return $0.h3IndexRes6.isEmpty ? nil : $0.h3IndexRes6
        })
        let flightRaw = TransitMode.flight.rawValue
        let hiddenHexes = try HexVisibility.hiddenHexes(
            transit: transitStays.map {
                try checkCancellation()
                return HexVisibility.TransitStay(
                    h3Index: $0.h3IndexRes6,
                    // Stored-field compare; only the exact "flight" raw value
                    // decodes to `.flight`, so this matches `transitMode == .flight`.
                    isFlight: $0.transitFromPreviousRaw == flightRaw,
                    isAirport: $0.isAirport
                )
            },
            realHexes: realHexes
        )
        // Every hex counter counts cells, not rows: `HexVisitDeduplicator`
        // keeps ambiguous same-cell groups. A cell's first visit is its
        // earliest row's, and it counts once in each country its rows carry.
        var firstVisitByCell: [String: Date] = [:]
        var countryCells: [String: (name: String?, cells: Set<String>)] = [:]
        for hexVisit in hexVisits {
            try checkCancellation()
            let cell = hexVisit.h3Index
            let firstVisited = hexVisit.firstVisited
            firstVisitByCell[cell] = min(firstVisitByCell[cell] ?? firstVisited, firstVisited)
            guard let code = hexVisit.isoCountryCode else { continue }
            // In place: a copied-out entry would copy its whole set per row.
            countryCells[code, default: (nil, [])].cells.insert(cell)
            if countryCells[code]?.name == nil { countryCells[code]?.name = hexVisit.country }
        }

        // HexVisibility.isVisible drops boundary failures from both map rendering and Stats counts.
        let visibleCells = try Set(firstVisitByCell.keys.filter {
            try checkCancellation()
            return HexVisibility.isVisible(
                h3Index: $0,
                hidden: hiddenHexes,
                isRenderable: { H3Service.cellBoundary(for: $0) != nil }
            )
        })
        result.totalHexes = visibleCells.count

        // Exploration metrics: the (map-scale) HexVisit rows cover both the
        // new-this-year count and the per-country concentration. Both count
        // only the visible cells, so they agree with the total and the map.
        var gregorian = TravelDays.labelCalendar
        gregorian.timeZone = calendar.timeZone
        let yearStart = gregorian.date(
            from: gregorian.dateComponents([.year], from: now)
        ) ?? .distantFuture
        result.newHexesThisYear = try firstVisitByCell.count {
            try checkCancellation()
            return $0.value >= yearStart && visibleCells.contains($0.key)
        }
        var newByYear: [Int: Int] = [:]
        for (cell, firstVisited) in firstVisitByCell where visibleCells.contains(cell) {
            try checkCancellation()
            newByYear[gregorian.component(.year, from: firstVisited), default: 0] += 1
        }
        result.newHexesByYear = newByYear
            .sorted { $0.key < $1.key }
            .map { HexYear(year: $0.key, count: $0.value) }

        let byCountry = countryCells.mapValues { (name: $0.name, count: $0.cells.count { visibleCells.contains($0) }) }
        // Keep six candidates so pinned home countries leave room for three non-home leaders, including dual homes.
        result.topHexCountries = byCountry
            .filter { $0.value.count > 0 }
            .map { HexCountry(code: $0.key, name: $0.value.name, count: $0.value.count) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.code < rhs.code
            }
            .prefix(6)
            .map { $0 }

        // Pinned "% of home explored" rows — one per country hosting an
        // active Home. Count 0 is deliberate: the pin renders even before
        // the first hex lands in a freshly-moved-to country.
        result.homeHexCountries = homeCountryCodes
            .map { code -> HexCountry in
                let entry = byCountry[code]
                return HexCountry(code: code, name: entry?.name, count: entry?.count ?? 0)
            }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.code < rhs.code
            }

        // The days-away ledger already retains this compute's trip labels.
        // Reuse them for the trip-only counters, year ledger and favourite
        // month; without a successful ledger, label the trip spans. One
        // boundary walk per trip (the ledger's when it ran) also serves the
        // year ledger and Passport durations.
        try checkCancellation()
        let spans = try tripSpans ?? TravelDays.spans(trips: trips, checkCancellation: checkCancellation)
        // Aligned with `completedTrips`: the same filter over the same order.
        let completedSpans = zip(trips, spans).compactMap { trip, span in trip.isComplete ? span : nil }
        let days = try awayLedger?.travelling ?? TravelDays.labels(
            spans: spans, now: now, fallbackZone: calendar.timeZone, checkCancellation: checkCancellation)
        let travel = try travelDays(from: days, now: now, calendar: calendar, checkCancellation: checkCancellation)
        result.travelDaysThisYear = travel.thisYear
        result.travelDaysTotal = travel.total
        result.yearStats = try yearStats(
            days: days, completedTrips: completedTrips, spans: completedSpans, calendar: calendar,
            checkCancellation: checkCancellation)
        // The month strip and the favourite month share one pass.
        let monthBins = try monthTravelDays(days: days, checkCancellation: checkCancellation)
        result.monthTravelDays = monthBins
        // The current label year, as `travelDays` reads it.
        let currentYear = gregorian.component(.year, from: now)
        result.monthTravelDaysThisYear = try monthTravelDays(
            days: days.filter {
                try checkCancellation()
                return TravelDays.labelCalendar.component(.year, from: $0) == currentYear
            },
            checkCancellation: checkCancellation)
        if let favourite = favoriteMonth(bins: monthBins) {
            result.favoriteMonth = favourite.month
            result.favoriteMonthDays = favourite.days
        }
        // Days lived at a temporary home join Passport's days away. The
        // counters above stay trip-only.
        if let awayLedger {
            let away = try travelDays(from: awayLedger.away, now: now, calendar: calendar,
                                      checkCancellation: checkCancellation)
            result.awayDaysTotal = away.total
            result.awayDaysThisYear = away.thisYear
            result.stayingDaysTotal = awayLedger.staying.count
        }

        result.onThisDayGroups = try onThisDayGroups(destinationStays: destinationStays, now: now, calendar: calendar, checkCancellation: checkCancellation)
        try checkCancellation()
        result.uniqueCountries = uniqueCountries(
            visitedCodes: visitedStays.map { $0.isoCountryCode }, completedTrips: completedTrips)
        try checkCancellation()
        let dayLabels = try dayLabelsByCountry(
            destinationStays: destinationStays, calendar: calendar, checkCancellation: checkCancellation)
        result.countryStats = countryStats(
            visitedStays: visitedStays,
            // Include ongoing trips so each country row agrees with the trips-list filter its tap opens.
            trips: trips,
            homeCountryCodes: homeCountryCodes,
            anchors: anchors,
            daysByCountry: dayLabels.mapValues(\.count)
        )
        result.countryDaysThisYear = try dayLabels
            .compactMap { code, labels -> CountryDays? in
                let count = try TravelDays.count(labels, inYear: currentYear, checkCancellation: checkCancellation)
                return count > 0 ? CountryDays(code: code, days: count) : nil
            }
            .sorted { lhs, rhs in
                if lhs.days != rhs.days { return lhs.days > rhs.days }
                return lhs.code < rhs.code
            }
        var citiesThisYear = Stay.CityCountAccumulator()
        // The year of the stay's own civil start, like the country days and
        // stamps: a stay starting just after midnight on 1 January belongs
        // to the new year wherever the device is.
        var zonedCalendars: [String?: Calendar] = [:]
        for stay in destinationStays where stay.tripID != nil {
            try checkCancellation()
            let zoned = zonedCalendars[stay.timeZoneIdentifier] ?? {
                var zoned = gregorian
                zoned.timeZone = StayTimeZone.resolve(stay.timeZoneIdentifier, fallback: calendar.timeZone)
                zonedCalendars[stay.timeZoneIdentifier] = zoned
                return zoned
            }()
            guard zoned.component(.year, from: stay.startTime) == currentYear else { continue }
            citiesThisYear.add(h3IndexRes6: stay.h3IndexRes6,
                               latitude: stay.centroidLatitude, longitude: stay.centroidLongitude)
        }
        result.citiesThisYear = try citiesThisYear.count(thresholdKm: 25, checkCancellation: checkCancellation)
        let stampVisits = destinationStays.compactMap { stay -> StampVisit? in
            guard let code = stay.isoCountryCode, stay.tripID != nil else { return nil }
            return StampVisit(id: stay.id, code: code, startTime: stay.startTime,
                              timeZoneIdentifier: stay.timeZoneIdentifier, tripID: stay.tripID)
        }
        result.stampYears = try stampYears(
            visits: stampVisits,
            ongoingTripIDs: Set(trips.filter { !$0.isComplete }.map(\.id)),
            fallbackZone: calendar.timeZone,
            checkCancellation: checkCancellation)
        // `Trip.durationDays` from the already-walked boundary spans: the same
        // boundary stays and device-zone fallback, without walking stays
        // again. Aligned with `completedTrips`; shared by Passport, the
        // trip-length buckets and Last Trip.
        let durations = try completedSpans.map { span in
            try checkCancellation()
            return span.end.map {
                Trip.inclusiveDays(from: span.start, in: StayTimeZone.resolve(span.firstZone),
                                   to: $0, in: StayTimeZone.resolve(span.lastZone))
            } ?? 0
        }
        result.tripLengthBuckets = tripLengthBuckets(tripIDs: completedTrips.map(\.id), durations: durations)
        // Ties on identical `startDate` timestamps break on id so two
        // launches (or two devices) never disagree about "Last Trip".
        try checkCancellation()
        result.lastTrip = completedTrips.indices
            .max(by: { lhs, rhs in
                let l = completedTrips[lhs], r = completedTrips[rhs]
                if l.startDate != r.startDate { return l.startDate < r.startDate }
                return l.id.uuidString < r.id.uuidString
            })
            .map { index in
                let trip = completedTrips[index]
                return LastTrip(name: trip.displayName, date: trip.startDate, tripID: trip.id,
                                days: durations[index] > 0 ? durations[index] : nil,
                                endDate: completedSpans[index].end)
            }
        try checkCancellation()
        let firstRecorded = try firstRecordedCountries(
            visited: visitedStays, unclassified: unclassifiedStays,
            knownTemporaryHomeIDs: Set(anchors.filter(\.isTemporary).map(\.id)),
            checkCancellation: checkCancellation)
        result.firstRecordedCountries = firstRecorded
        result.firstEverStampYears = try firstEverStampYears(
            firstRecorded: firstRecorded, visits: stampVisits,
            fallbackZone: calendar.timeZone, checkCancellation: checkCancellation)
        // Home/routine and unclassified stays participate as flight-leg predecessors without becoming entries.
        // Skipping backlog predecessors would assign the wrong departure route, ISO, zone, and date window.
        // Before Passport, whose Flights tile is the Flight Log's count.
        try checkCancellation()
        result.collections = try CollectionsAggregator.aggregate(
            rows: visitedStays + transitStays,
            predecessorOnly: unclassifiedStays,
            checkCancellation: checkCancellation
        )
        try checkCancellation()
        result.passportData = try passportData(
            uniqueCountries: result.uniqueCountries,
            completedTrips: completedTrips,
            durations: durations,
            visitedStays: visitedStays,
            destinationStays: destinationStays,
            totals: result,
            anchors: farthestAnchors ?? anchors,
            now: now,
            calendar: calendar,
            checkCancellation: checkCancellation
        )
        try checkCancellation()
        return result
    }

    // MARK: - Travel days

    /// Distinct calendar days touched by any trip; an ongoing trip counts
    /// through `now` (elapsed-so-far, Wrapped's `effectiveDurationDays`
    /// stance). Days dedup across trips via one set, so a same-day
    /// return-and-depart never counts twice. Boundary time zones supply civil
    /// dates, with the injected calendar's zone as fallback. Internal as a
    /// test seam.
    static func travelDays(
        trips: [Trip],
        now: Date,
        calendar: Calendar = .current
    ) -> (thisYear: Int, total: Int) {
        travelDays(from: travelDaySet(trips: trips, now: now, calendar: calendar),
                   now: now, calendar: calendar, checkCancellation: {})
    }

    /// Bound day walks so corrupted ancient dates cannot cause unbounded Stats work.
    private static let maxSpanDays = 3_650

    /// Every Gregorian date label in `[start, end]`, clamped to `maxSpanDays`
    /// ending at `end`. An end label before the start yields just the start.
    private static func dayWalk(
        fromLabel start: Date, toLabel end: Date, into days: inout Set<Date>,
        checkCancellation: () throws -> Void
    ) rethrows {
        let calendar = TravelDays.labelCalendar
        var day = start
        let endDay = max(start, end)
        if let span = calendar.dateComponents([.day], from: day, to: endDay).day,
           span > maxSpanDays,
           let clamped = calendar.date(byAdding: .day, value: -maxSpanDays, to: endDay) {
            day = clamped
        }
        while day <= endDay {
            try checkCancellation()
            days.insert(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
    }

    /// Civil date labels, encoded at UTC midnight (ongoing → now).
    static func travelDaySet(trips: [Trip], now: Date, calendar: Calendar) -> Set<Date> {
        travelDaySet(trips: trips, now: now, calendar: calendar, checkCancellation: {})
    }

    static func travelDaySet(
        trips: [Trip], now: Date, calendar: Calendar,
        checkCancellation: () throws -> Void
    ) rethrows -> Set<Date> {
        try TravelDays.labels(trips: trips, now: now, fallbackZone: calendar.timeZone,
                              checkCancellation: checkCancellation)
    }

    private static func travelDays(
        from days: Set<Date>, now: Date, calendar: Calendar,
        checkCancellation: () throws -> Void
    ) rethrows -> (thisYear: Int, total: Int) {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = calendar.timeZone
        return (try TravelDays.count(days, inYear: local.component(.year, from: now),
                                     checkCancellation: checkCancellation), days.count)
    }

    /// Gregorian label-year ledger: completed trips use their first stay's
    /// boundary zone, matching TravelDays, and union their country codes.
    /// `calendar` supplies only the fallback time zone. Ascending.
    /// Internal as a test seam.
    static func yearStats(
        days: Set<Date>, completedTrips: [Trip], calendar: Calendar
    ) -> [YearStat] {
        yearStats(days: days, completedTrips: completedTrips,
                  spans: TravelDays.spans(trips: completedTrips, checkCancellation: {}),
                  calendar: calendar, checkCancellation: {})
    }

    /// `spans` are `TravelDays.spans(trips: completedTrips)`, index for index.
    static func yearStats(
        days: Set<Date>, completedTrips: [Trip], spans: [TravelDays.Span], calendar: Calendar,
        checkCancellation: () throws -> Void
    ) rethrows -> [YearStat] {
        var byYear: [Int: YearStat] = [:]
        for day in days {
            try checkCancellation()
            let year = TravelDays.labelCalendar.component(.year, from: day)
            byYear[year, default: YearStat(year: year)].days += 1
        }
        var codesByYear: [Int: Set<String>] = [:]
        // Distinct ids, as the stats widget counts: same-UUID twins are one trip.
        var tripIDsByYear: [Int: Set<UUID>] = [:]
        for (trip, span) in zip(completedTrips, spans) {
            try checkCancellation()
            guard let label = TravelDays.label(for: span.start, zone: StayTimeZone.resolve(
                span.firstZone, fallback: calendar.timeZone)) else { continue }
            let year = TravelDays.labelCalendar.component(.year, from: label)
            tripIDsByYear[year, default: []].insert(trip.id)
            for code in trip.countryCodes.split(separator: ",") where !code.isEmpty {
                codesByYear[year, default: []].insert(String(code))
            }
        }
        for (year, ids) in tripIDsByYear {
            byYear[year, default: YearStat(year: year)].trips = ids.count
        }
        for (year, codes) in codesByYear {
            byYear[year]?.countries = codes.count
        }
        return byYear.values.sorted { $0.year < $1.year }
    }

    /// The Gregorian month with the most travel days, all years pooled.
    /// `calendar` is retained for callers; UTC label bucketing ignores it.
    /// Ties break on the earlier month so two devices agree.
    static func favoriteMonth(days: Set<Date>, calendar: Calendar) -> (month: Int, days: Int)? {
        favoriteMonth(days: days, calendar: calendar, checkCancellation: {})
    }

    static func favoriteMonth(
        days: Set<Date>, calendar: Calendar,
        checkCancellation: () throws -> Void
    ) rethrows -> (month: Int, days: Int)? {
        favoriteMonth(bins: try monthTravelDays(days: days, checkCancellation: checkCancellation))
    }

    /// The favourite month of `monthTravelDays` bins: the most days, ties to
    /// the earlier month; nil when no month has a day.
    static func favoriteMonth(bins: [Int]) -> (month: Int, days: Int)? {
        var best: (month: Int, days: Int)?
        for (index, count) in bins.enumerated() where count > (best?.days ?? 0) {
            best = (index + 1, count)
        }
        return best
    }

    /// Travel days per Gregorian month (index 0 is January), all years
    /// pooled. Day labels bucket by `labelCalendar`, as the year ledger does.
    static func monthTravelDays(
        days: Set<Date>, checkCancellation: () throws -> Void
    ) rethrows -> [Int] {
        var bins = Array(repeating: 0, count: 12)
        for day in days {
            try checkCancellation()
            let month = TravelDays.labelCalendar.component(.month, from: day)
            if bins.indices.contains(month - 1) { bins[month - 1] += 1 }
        }
        return bins
    }

    /// Completed trips per length bucket (`tripLengthBucketUpperBounds`).
    /// Same-UUID twins are one trip, as Passport counts, at the longer of
    /// their lengths; a trip of unknown (zero) length is left out.
    static func tripLengthBuckets(tripIDs: [UUID], durations: [Int]) -> [Int] {
        var longest: [UUID: Int] = [:]
        for (id, days) in zip(tripIDs, durations) where days > 0 {
            longest[id] = max(longest[id] ?? 0, days)
        }
        let bounds = tripLengthBucketUpperBounds
        var buckets = Array(repeating: 0, count: bounds.count + 1)
        for days in longest.values {
            buckets[bounds.firstIndex { days <= $0 } ?? bounds.count] += 1
        }
        return buckets
    }

    /// Wrapped's new-country rule (`YearWrappedGenerator.computeStats`),
    /// for every year in one pass. A country is new in year Y when a
    /// trip-member destination stay or a home stay a temporary home recorded
    /// as its own starts in Y, no non-transit stay starts before Y, and no
    /// home stay of the real Home in Y carries it. Years are Wrapped's UTC
    /// Gregorian windows over `startTime`. Since a new country's first
    /// evidence lies in Y itself, each country is new in at most its first
    /// evidence year. `unclassified` are the non-transit stays outside
    /// `visited` (Wrapped's prior read admits every category but transit).
    static func firstRecordedCountries(
        visited: [CollectionsAggregator.StayRow],
        unclassified: [CollectionsAggregator.Endpoint],
        knownTemporaryHomeIDs: Set<UUID>,
        checkCancellation: () throws -> Void
    ) rethrows -> [FirstRecordedYear] {
        let calendar = TravelDays.labelCalendar
        var firstYear: [String: Int] = [:]
        var geographyYears: [String: Set<Int>] = [:]
        var realHomeYears: [String: Set<Int>] = [:]
        for stay in visited {
            try checkCancellation()
            guard let code = stay.isoCountryCode else { continue }
            let year = calendar.component(.year, from: stay.startTime)
            firstYear[code] = min(firstYear[code] ?? year, year)
            if stay.categoryRaw == StayCategory.destination.rawValue {
                if stay.tripID != nil { geographyYears[code, default: []].insert(year) }
            } else if stay.categoryRaw == StayCategory.home.rawValue {
                switch HomeAnchors.recordedOwner(
                    temporaryHomeID: stay.temporaryHomeID, knownTemporaryHomeIDs: knownTemporaryHomeIDs) {
                case .realHome: realHomeYears[code, default: []].insert(year)
                case .temporary: geographyYears[code, default: []].insert(year)
                case .unresolved: break
                }
            }
        }
        for stay in unclassified {
            try checkCancellation()
            guard let code = stay.isoCountryCode else { continue }
            let year = calendar.component(.year, from: stay.startTime)
            firstYear[code] = min(firstYear[code] ?? year, year)
        }
        var codesByYear: [Int: [String]] = [:]
        for (code, year) in firstYear
        where geographyYears[code]?.contains(year) == true && realHomeYears[code]?.contains(year) != true {
            codesByYear[year, default: []].append(code)
        }
        return codesByYear.keys.sorted().map { FirstRecordedYear(year: $0, codes: codesByYear[$0, default: []].sorted()) }
    }

    /// Distinct date labels per country, read in each stay's own zone
    /// (the injected calendar's zone as fallback), from destination stays that
    /// belong to a trip (gate-suppressed errand residue is `.destination`
    /// but tripless, and must not stamp days onto the home country).
    static func daysByCountry(destinationStays: [Stay], calendar: Calendar) -> [String: Int] {
        daysByCountry(
            destinationStays: destinationStays.map { CollectionsAggregator.StayRow($0, anyCategory: true) },
            calendar: calendar, checkCancellation: {})
    }

    static func daysByCountry(
        destinationStays: [CollectionsAggregator.StayRow], calendar: Calendar,
        checkCancellation: () throws -> Void
    ) rethrows -> [String: Int] {
        try dayLabelsByCountry(destinationStays: destinationStays, calendar: calendar,
                               checkCancellation: checkCancellation).mapValues(\.count)
    }

    /// The date labels behind `daysByCountry`, per country.
    static func dayLabelsByCountry(
        destinationStays: [CollectionsAggregator.StayRow], calendar: Calendar,
        checkCancellation: () throws -> Void
    ) rethrows -> [String: Set<Date>] {
        var daysByCode: [String: Set<Date>] = [:]
        for stay in destinationStays {
            try checkCancellation()
            guard let code = stay.isoCountryCode, stay.tripID != nil else { continue }
            let zone = StayTimeZone.resolve(stay.timeZoneIdentifier, fallback: calendar.timeZone)
            guard let startLabel = TravelDays.label(for: stay.startTime, zone: zone),
                  let endLabel = TravelDays.label(for: max(stay.startTime, stay.endTime), zone: zone)
            else { continue }
            try dayWalk(fromLabel: startLabel, toLabel: endLabel,
                        into: &daysByCode[code, default: []], checkCancellation: checkCancellation)
        }
        return daysByCode
    }

    /// The expanded Passport's stamp pages. A stamp is a country's first
    /// entry in a Gregorian label year: the earliest trip-member destination
    /// stay there, dated in the stay's own zone (`fallbackZone` when it has
    /// none). Equal labels break on start time, then id, so every device
    /// draws the same page. Years ascend; a page lists its stamps by entry
    /// date, then code.
    static func stampYears(
        visits: [StampVisit], ongoingTripIDs: Set<UUID>, fallbackZone: TimeZone,
        checkCancellation: () throws -> Void
    ) rethrows -> [StampYear] {
        struct Key: Hashable { let year: Int; let code: String }
        var first: [Key: (day: Date, visit: StampVisit)] = [:]
        for visit in visits {
            try checkCancellation()
            guard let day = TravelDays.label(
                for: visit.startTime,
                zone: StayTimeZone.resolve(visit.timeZoneIdentifier, fallback: fallbackZone)) else { continue }
            let key = Key(year: TravelDays.labelCalendar.component(.year, from: day), code: visit.code)
            if let existing = first[key] {
                let earlier = day != existing.day ? day < existing.day
                    : TravelDays.startsFirst(visit.startTime, visit.id,
                                             before: existing.visit.startTime, existing.visit.id)
                guard earlier else { continue }
            }
            first[key] = (day, visit)
        }
        var byYear: [Int: [StampEntry]] = [:]
        for (key, entry) in first {
            let ongoing = entry.visit.tripID.map { ongoingTripIDs.contains($0) } ?? false
            byYear[key.year, default: []].append(
                StampEntry(code: key.code, day: entry.day, isOngoing: ongoing ? true : nil))
        }
        return byYear.keys.sorted().map { year in
            StampYear(year: year, stamps: byYear[year, default: []].sorted { lhs, rhs in
                if lhs.day != rhs.day { return lhs.day < rhs.day }
                return lhs.code < rhs.code
            })
        }
    }

    /// The stamp page each first-ever mark belongs on. Eligibility stays
    /// `firstRecorded`'s (UTC years, Wrapped's rule); the mark moves to the
    /// stamp year of the earliest trip-member destination stay that recorded
    /// the country in its eligible year, filed in the stay's own zone as its
    /// stamp is. A first visit at 23:30 UTC on 31 December is 1 January in
    /// Athens, so its mark lands on the next year's page. A country first
    /// recorded only at a temporary home has no stamp that year, and no mark.
    /// Ascending by stamp year, sorted codes.
    static func firstEverStampYears(
        firstRecorded: [FirstRecordedYear], visits: [StampVisit], fallbackZone: TimeZone,
        checkCancellation: () throws -> Void
    ) rethrows -> [FirstRecordedYear] {
        var eligibleYear: [String: Int] = [:]
        for entry in firstRecorded {
            for code in entry.codes { eligibleYear[code] = entry.year }
        }
        var earliest: [String: StampVisit] = [:]
        for visit in visits {
            try checkCancellation()
            guard let year = eligibleYear[visit.code],
                  TravelDays.labelCalendar.component(.year, from: visit.startTime) == year else { continue }
            if let existing = earliest[visit.code],
               !TravelDays.startsFirst(visit.startTime, visit.id, before: existing.startTime, existing.id) {
                continue
            }
            earliest[visit.code] = visit
        }
        var codesByYear: [Int: [String]] = [:]
        for (code, visit) in earliest {
            try checkCancellation()
            guard let day = TravelDays.label(
                for: visit.startTime,
                zone: StayTimeZone.resolve(visit.timeZoneIdentifier, fallback: fallbackZone)) else { continue }
            codesByYear[TravelDays.labelCalendar.component(.year, from: day), default: []].append(code)
        }
        return codesByYear.keys.sorted().map { FirstRecordedYear(year: $0, codes: codesByYear[$0, default: []].sorted()) }
    }

    // MARK: - Year summary (App Intents)

    struct YearSummary: Sendable, Equatable {
        let year: Int
        var trips = 0
        var countries: Set<String> = []
        var daysAbroad = 0
        var flights = 0
    }

    /// Fresh off-main context reads committed state; return the four canonical lifetime totals for TravelStatsIntent.
    /// Countries are tracked-only: the caller must union remembered countries as passportData does.
    /// Preserve uniqueCountries’ two-source union, completed-trip count, travel-date union, and flight-leg count.
    struct PassportSummary: Sendable {
        var countries: Set<String> = []
        var trips = 0
        var daysAbroad = 0
        var flights = 0
    }

    /// Throws when any required read fails: a failed read is not an empty
    /// history, so Siri must never speak it as "no trips".
    static func passportSummary(
        container: ModelContainer, now: Date = .now, calendar: Calendar = .current,
        checkCancellation: () throws -> Void = {}
    ) throws -> PassportSummary {
        try checkCancellation()
        let context = ModelContext(container)
        var summary = PassportSummary()

        // Only `isoCountryCode` is consumed from the visited stays — skip
        // the heavy columns (weatherData blob, pingIDsString), same budget
        // reasoning as the widget providers.
        var visitedDescriptor = FetchDescriptor<Stay>(predicate: Stay.visitedCategoriesPredicate())
        visitedDescriptor.propertiesToFetch = [\.isoCountryCode]
        try checkRead(.lifetimeVisited)
        let visitedStays = try context.fetch(visitedDescriptor)
        try checkCancellation()

        var tripDescriptor = FetchDescriptor<Trip>(predicate: #Predicate { $0.isComplete == true })
        tripDescriptor.propertiesToFetch = [\.id, \.countryCodes]
        try checkRead(.lifetimeCompletedTrips)
        let completedTrips = try context.fetch(tripDescriptor)
        try checkCancellation()

        let flightRaw = TransitMode.flight.rawValue
        try checkRead(.lifetimeFlights)
        summary.flights = try context.fetchCount(FetchDescriptor<Stay>(
            predicate: #Predicate { $0.transitFromPreviousRaw == flightRaw }
        ))
        try checkCancellation()

        summary.countries = uniqueCountries(
            visitedCodes: visitedStays.map { $0.isoCountryCode }, completedTrips: completedTrips)
        // Distinct ids, as the stats widget counts: same-UUID twins are one trip.
        summary.trips = Set(completedTrips.map(\.id)).count
        try checkRead(.lifetimeTravelDays)
        let travelling = try TravelDays.labels(
            container: container, now: now, fallbackZone: calendar.timeZone,
            checkCancellation: checkCancellation)
        // Days away add the days lived at a temporary home; with none
        // declared this is the trip labels after one extra fetch.
        summary.daysAbroad = try TemporaryHomeLedger.result(
            travelling: travelling, container: container, now: now,
            fallbackZone: calendar.timeZone, checkCancellation: checkCancellation).away.count
        return summary
    }

    /// Scoping rules mirror the existing lifetime semantics:
    /// - trips = completed trips whose first Gregorian date label falls
    ///   in the year, using the same boundary zone as TravelDays;
    /// - countries = destination-stay ISO codes for stays starting in the
    ///   year, unioned with the counted trips' `countryCodes` (the
    ///   `uniqueCountries` two-source union, year-scoped);
    /// - flights = stays whose leg-in was a flight, starting in the year;
    /// - days = distinct civil dates in the year across all trip spans,
    ///   including carry-in and ongoing trips, independent of the count scope.
    /// `year` is Gregorian. `calendar` supplies the fallback boundary zone
    /// and the time zone for the Gregorian destination/flight fetch window.
    /// Throws when any required read fails; an out-of-range year is input
    /// validation and still returns an empty summary.
    static func yearSummary(
        container: ModelContainer,
        year: Int,
        calendar: Calendar = .current,
        now: Date = .now,
        checkCancellation: () throws -> Void = {}
    ) throws -> YearSummary {
        // Clamp Siri’s year before year + 1 to prevent checked-add overflow.
        var gregorian = TravelDays.labelCalendar
        gregorian.timeZone = calendar.timeZone
        guard year > 0, year < 10_000,
              let yearStart = gregorian.date(from: DateComponents(year: year)),
              let yearEnd = gregorian.date(from: DateComponents(year: year + 1)) else {
            return YearSummary(year: year)
        }
        try checkCancellation()
        let context = ModelContext(container)

        // A raw start-date window loses trips whose first local label is
        // across New Year. Project boundary stays without faulting Trip.stays
        // or weather/ping payloads; UUID twins keep distinct physical parents.
        var boundaryDescriptor = FetchDescriptor<Stay>(predicate: #Predicate { $0.trip != nil })
        boundaryDescriptor.propertiesToFetch = [\.id, \.startTime, \.endTime, \.timeZoneIdentifier, \.trip]
        // A failed boundary read would silently bucket trips by the device
        // zone instead of the stay zone, so it is required too.
        try checkRead(.yearBoundaries)
        let boundaryStays = try context.fetch(boundaryDescriptor)
        var tripDescriptor = FetchDescriptor<Trip>()
        tripDescriptor.propertiesToFetch = [\.id, \.startDate, \.endDate, \.isComplete, \.countryCodes]
        try checkRead(.yearCompletedTrips)
        let trips = try context.fetch(tripDescriptor)
        let spans = try TravelDays.projectedSpans(trips: trips, boundaryStays: boundaryStays,
                                                 checkCancellation: checkCancellation)
        let completedTrips = try trips.filter { trip in
            try checkCancellation()
            guard trip.isComplete else { return false }
            let firstZone = spans[trip.persistentModelID]?.firstZone
            guard let label = TravelDays.label(for: trip.startDate, zone: StayTimeZone.resolve(
                firstZone, fallback: calendar.timeZone)) else { return false }
            return TravelDays.labelCalendar.component(.year, from: label) == year
        }
        try checkCancellation()
        try checkRead(.yearTravelDays)
        let travelling = try TravelDays.labels(
            spans: Array(spans.values), now: now, fallbackZone: calendar.timeZone,
            checkCancellation: checkCancellation)
        // The same away set as the lifetime summary, bucketed by label year.
        let dayCount = try TravelDays.count(
            TemporaryHomeLedger.result(
                travelling: travelling, container: container, now: now,
                fallbackZone: calendar.timeZone, checkCancellation: checkCancellation).away,
            inYear: year, checkCancellation: checkCancellation)
        var destinationDescriptor = FetchDescriptor<Stay>(
            predicate: #Predicate {
                // Trip members only: gate-suppressed errand residue is
                // `.destination` but tripless, and "how many countries did I
                // visit" must not gain the home country from a beach evening.
                $0.categoryRaw == "destination" && $0.trip != nil
                    && $0.startTime >= yearStart && $0.startTime < yearEnd
            }
        )
        // The year-country union reads only this scalar; avoid fetching
        // weather and ping payloads for every destination in the year.
        destinationDescriptor.propertiesToFetch = [\.isoCountryCode]
        try checkRead(.yearDestinations)
        let destinationStays = try context.fetch(destinationDescriptor)
        try checkCancellation()
        let flightRaw = TransitMode.flight.rawValue
        try checkRead(.yearFlights)
        let flightCount = try context.fetchCount(FetchDescriptor<Stay>(
            predicate: #Predicate {
                $0.transitFromPreviousRaw == flightRaw && $0.startTime >= yearStart && $0.startTime < yearEnd
            }
        ))
        try checkCancellation()

        return yearSummary(
            completedTrips: completedTrips,
            destinationStays: destinationStays,
            flightCount: flightCount,
            year: year,
            calendar: calendar,
            dayCount: dayCount,
            now: now
        )
    }

    /// Pure year reducer test seam over already-fetched rows.
    static func yearSummary(
        completedTrips: [Trip],
        destinationStays: [Stay],
        flightCount: Int,
        year: Int,
        calendar: Calendar = .current,
        dayTrips: [Trip]? = nil,
        dayCount: Int? = nil,
        now: Date = .now
    ) -> YearSummary {
        var summary = YearSummary(year: year)
        // Distinct ids, as the stats widget counts: same-UUID twins are one trip.
        summary.trips = Set(completedTrips.map(\.id)).count
        summary.daysAbroad = dayCount ?? TravelDays.count(
            TravelDays.labels(trips: dayTrips ?? completedTrips, now: now,
                              fallbackZone: calendar.timeZone),
            inYear: year)
        summary.flights = flightCount
        for stay in destinationStays {
            if let code = stay.isoCountryCode {
                summary.countries.insert(code)
            }
        }
        for trip in completedTrips {
            for code in trip.countryCodes.split(separator: ",") where !code.isEmpty {
                summary.countries.insert(String(code))
            }
        }
        return summary
    }

    // MARK: - Reductions

    /// Build today's "On This Day" groups from the destination stays.
    /// Pure engine — see `OnThisDayEngine`.
    private static func onThisDayGroups(
        destinationStays: [CollectionsAggregator.StayRow], now: Date, calendar: Calendar,
        checkCancellation: () throws -> Void
    ) rethrows -> [OnThisDayYearGroup] {
        try checkCancellation()
        let unordered = try destinationStays.map { stay in
            try checkCancellation()
            return OnThisDayStay(
                stayID: stay.id,
                tripID: stay.tripID,
                place: stay.placeGroupName,
                startTime: stay.startTime,
                endTime: stay.endTime,
                weatherConditionRaw: stay.model.weatherConditionRaw,
                avgTemperatureC: stay.avgTemperatureC,
                isoCountryCode: stay.isoCountryCode
            )
        }
        // Sort by startTime then id because OnThisDayEngine preserves name order and selects the first weather value.
        let snapshots = unordered.sorted {
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            return $0.stayID.uuidString < $1.stayID.uuidString
        }
        return try OnThisDayEngine.yearGroups(on: now, stays: snapshots, calendar: calendar,
                                             checkCancellation: checkCancellation)
    }

    /// Union visited-stay ISO codes with completed-trip countryCodes so globe and country-list sources agree.
    private static func uniqueCountries(visitedCodes: [String?], completedTrips: [Trip]) -> Set<String> {
        var codes = Set<String>()
        for code in visitedCodes {
            if let code {
                codes.insert(code)
            }
        }
        for trip in completedTrips {
            for code in trip.countryCodes.split(separator: ",") where !code.isEmpty {
                codes.insert(String(code))
            }
        }
        return codes
    }

    private static func countryStats(
        visitedStays: [CollectionsAggregator.StayRow],
        trips: [Trip],
        homeCountryCodes: Set<String>,
        anchors: [HomeAnchor] = [],
        daysByCountry: [String: Int] = [:]
    ) -> [CountryStat] {
        var stats: [String: CountryStat] = [:]
        // Countries of temporary homes, whatever their dates. A temporary
        // home with no stamped country takes it from the home stays it owns.
        let temporaryHomes = Dictionary(
            anchors.filter(\.isTemporary).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let temporaryHomeIDs = Set(temporaryHomes.keys)
        var temporaryHomeCodes = Set(temporaryHomes.values.compactMap(\.isoCountryCode))

        // OR home-ness across all rows per ISO; the unsorted fetch must not decide the badge.
        for stay in visitedStays {
            guard let code = stay.isoCountryCode else { continue }
            var isHome = stay.categoryRaw == StayCategory.home.rawValue
            // Only a home stay its writer recorded as the real Home's makes
            // its country "home", never the nearest centre. A removed or
            // unsynced owner is no live anchor here: nobody's.
            if isHome {
                switch HomeAnchors.recordedOwner(
                    temporaryHomeID: stay.temporaryHomeID, knownTemporaryHomeIDs: temporaryHomeIDs) {
                case .realHome:
                    break
                case .temporary(let id):
                    isHome = false
                    if temporaryHomes[id]?.isoCountryCode == nil { temporaryHomeCodes.insert(code) }
                case .unresolved:
                    isHome = false
                }
            }
            if stats[code] == nil {
                let name = stay.country ?? code
                stats[code] = CountryStat(code: code, name: name, tripCount: 0, isHome: isHome)
            } else if isHome {
                stats[code]?.isHome = true
            }
            let year = TravelDays.labelCalendar.component(.year, from: stay.startTime)
            let earliest = min(stats[code]?.firstYear ?? year, year)
            stats[code]?.firstYear = earliest
        }

        // Count trips per country — ongoing included (the row must agree
        // with the trips-list filter its tap opens). Same-UUID twins are
        // one trip, as in Passport.
        var tripIDsByCountry: [String: Set<UUID>] = [:]
        for trip in trips {
            let codes = trip.countryCodes.split(separator: ",").map(String.init)
            for code in codes {
                if stats[code] == nil {
                    // Destination stays are a subset of the seeded visited stays, so a name search cannot match.
                    stats[code] = CountryStat(code: code, name: code, tripCount: 0, isHome: false)
                }
                tripIDsByCountry[code, default: []].insert(trip.id)
            }
        }
        for (code, tripIDs) in tripIDsByCountry {
            stats[code]?.tripCount = tripIDs.count
        }

        // Active-home codes override historical home stays for the present-tense badge.
        // Retain stay-derived fallback when active homes lack geocoded country codes.
        if !homeCountryCodes.isEmpty {
            for code in stats.keys {
                stats[code]?.isHome = homeCountryCodes.contains(code)
            }
        }

        for code in temporaryHomeCodes where stats[code]?.isHome == false {
            stats[code]?.isTemporaryHome = true
        }

        for (code, days) in daysByCountry where days > 0 {
            stats[code]?.days = days
        }

        // Break equal trip counts alphabetically; dictionary iteration must not determine country order.
        return stats.values.sorted { lhs, rhs in
            if lhs.tripCount != rhs.tripCount { return lhs.tripCount > rhs.tripCount }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Count distinct parent trips per destination place; exclude tripless stays.
    /// Match metroName ?? islandName ?? locality, as Trip.recomputeSummary and title grouping do.
    /// Places key like the Places collection: name and country, plus the
    /// admin area for a locality whose name and country carry conflicting
    /// admin areas; a nil-country place folds into its one same-named sibling.
    /// Equal counts break alphabetically for a stable winner.
    private static func mostVisitedCity(
        destinationStays: [CollectionsAggregator.StayRow]
    ) -> (name: String, count: Int)? {
        func isLocalityTier(_ stay: CollectionsAggregator.StayRow) -> Bool {
            stay.metroName?.isEmpty != false && stay.islandName?.isEmpty != false
        }
        var adminAreasByKey: [String: Set<String>] = [:]
        for stay in destinationStays where stay.tripID != nil && isLocalityTier(stay) {
            guard let locality = stay.locality, !locality.isEmpty,
                  let admin = stay.administrativeArea, !admin.isEmpty else { continue }
            adminAreasByKey["\(locality)|\(stay.isoCountryCode ?? "")", default: []].insert(admin)
        }
        var tripsByPlace: [String: (name: String, iso: String, tripIDs: Set<UUID>)] = [:]
        for stay in destinationStays {
            let placeName = stay.placeGroupName
            guard let placeName, !placeName.isEmpty,
                  let tripID = stay.tripID else { continue }
            var key = "\(placeName)|\(stay.isoCountryCode ?? "")"
            if isLocalityTier(stay), (adminAreasByKey[key]?.count ?? 0) > 1 {
                key += "|\(stay.administrativeArea ?? "")"
            }
            tripsByPlace[key, default: (placeName, stay.isoCountryCode ?? "", [])].tripIDs.insert(tripID)
        }
        for key in tripsByPlace.keys.filter({ $0.hasSuffix("|") }).sorted() {
            guard let orphan = tripsByPlace[key] else { continue }
            let siblings = tripsByPlace.filter { $0.key != key && $0.value.name == orphan.name && !$0.value.iso.isEmpty }
            guard siblings.count == 1, let sibling = siblings.first else { continue }
            tripsByPlace[sibling.key]?.tripIDs.formUnion(orphan.tripIDs)
            tripsByPlace[key] = nil
        }
        guard let top = tripsByPlace.max(by: { lhs, rhs in
            if lhs.value.tripIDs.count != rhs.value.tripIDs.count {
                return lhs.value.tripIDs.count < rhs.value.tripIDs.count
            }
            if lhs.value.name != rhs.value.name { return lhs.value.name > rhs.value.name }
            return lhs.key > rhs.key
        }) else { return nil }
        return (name: top.value.name, count: top.value.tripIDs.count)
    }


    /// Lifetime ledger for the passport card. `countries` deliberately
    /// counts only tracked data — the live remembered-countries overlay
    /// (`StatsView.passportDataForDisplay`) overwrites it with the KVS
    /// union so the checklist reacts without waiting for a data epoch.
    private static func passportData(
        uniqueCountries: Set<String>,
        completedTrips: [Trip],
        durations: [Int],
        visitedStays: [CollectionsAggregator.StayRow],
        destinationStays: [CollectionsAggregator.StayRow],
        totals: Aggregates,
        anchors: [HomeAnchor],
        now: Date,
        calendar: Calendar,
        checkCancellation: () throws -> Void
    ) rethrows -> PassportData {
        var data = PassportData()
        data.countries = uniqueCountries.count
        // `Stay.deduplicatedCityCount(from:)` (25 km) over the copied fields.
        try checkCancellation()
        var cities = Stay.CityCountAccumulator()
        for stay in visitedStays {
            try checkCancellation()
            cities.add(h3IndexRes6: stay.h3IndexRes6,
                       latitude: stay.centroidLatitude, longitude: stay.centroidLongitude)
        }
        data.cities = try cities.count(thresholdKm: 25, checkCancellation: checkCancellation)
        try checkCancellation()
        // Distinct ids, as the stats widget counts: same-UUID twins are one trip.
        data.trips = Set(completedTrips.map(\.id)).count
        data.daysAbroad = totals.awayDaysTotal ?? totals.travelDaysTotal ?? 0
        // Zero stays nil so an empty passport still equals `PassportData()`.
        if let staying = totals.stayingDaysTotal, staying > 0 {
            data.daysAtTemporaryHomes = staying
        }
        // `durations` are `Trip.durationDays`, aligned with `completedTrips`.
        if !completedTrips.isEmpty {
            let completedDays = durations.reduce(0, +)
            data.averageTripDays = Double(completedDays) / Double(completedTrips.count)
        }
        data.hexes = totals.totalHexes
        // The Flight Log's count (legs through the user's stops included),
        // so the tile and the Collections row agree. Siri's
        // `passportSummary` still counts flight-leg stays (any category,
        // geometry-less legs included).
        data.flights = totals.collections.flightStats.totalFlights
        // Share the sentinel-guarded winner and tie-break with Wrapped so unusable-home sentinels never win.
        // With a temporary home, measure from the real Home of each stay's start, as new recaps do.
        let realHomes = YearWrappedGenerator.farthestRealHomes(anchors)
        if let farthest = YearWrappedGenerator.farthestFromHome(
            destinations: destinationStays.map {
                (YearWrappedGenerator.farthestCandidateKm(
                    stamped: $0.model.distanceFromHomeKm, latitude: $0.centroidLatitude,
                    longitude: $0.centroidLongitude, startTime: $0.startTime, realHomes: realHomes),
                 $0.startTime, $0.id, $0.placeGroupName)
            }
        ) {
            data.furthestKm = farthest.distanceKm
            data.furthestPlace = farthest.name
        }
        if let since = totals.trackingSince {
            var gregorian = TravelDays.labelCalendar
            gregorian.timeZone = calendar.timeZone
            data.sinceYear = gregorian.component(.year, from: since)
        }

        // Detail-sheet extras (PassportDetailView).
        data.totalStays = totals.totalStays
        data.totalPings = totals.totalPings
        var gregorian = TravelDays.labelCalendar
        gregorian.timeZone = calendar.timeZone
        let year = gregorian.component(.year, from: now)
        data.tripsThisYear = totals.yearStats?.first { $0.year == year }?.trips ?? 0
        data.newHexesThisYear = totals.newHexesThisYear
        // Break equal durations by earlier start, then id for a stable winner.
        if let longest = zip(completedTrips, durations).max(by: { lhs, rhs in
            let l = lhs.1, r = rhs.1
            if l != r { return l < r }
            if lhs.0.startDate != rhs.0.startDate { return lhs.0.startDate > rhs.0.startDate }
            return lhs.0.id.uuidString > rhs.0.id.uuidString
        }) {
            data.longestTripName = longest.0.displayName
            data.longestTripDays = longest.1
        }
        if let mostVisited = mostVisitedCity(destinationStays: destinationStays) {
            data.mostVisitedPlace = mostVisited.name
            data.mostVisitedTripCount = mostVisited.count
        }
        let temperatureStays = visitedStays.filter { $0.avgTemperatureC != nil }
        if let hottest = temperatureStays.max(by: { lhs, rhs in
            let l = lhs.avgTemperatureC ?? 0, r = rhs.avgTemperatureC ?? 0
            if l != r { return l < r }
            return lhs.id.uuidString < rhs.id.uuidString
        }), let temp = hottest.avgTemperatureC {
            data.hottestTempC = temp
            data.hottestPlace = hottest.placeGroupName
        }
        if let coldest = temperatureStays.min(by: { lhs, rhs in
            let l = lhs.avgTemperatureC ?? 0, r = rhs.avgTemperatureC ?? 0
            if l != r { return l < r }
            return lhs.id.uuidString < rhs.id.uuidString
        }), let temp = coldest.avgTemperatureC {
            data.coldestTempC = temp
            data.coldestPlace = coldest.placeGroupName
        }
        return data
    }
}
