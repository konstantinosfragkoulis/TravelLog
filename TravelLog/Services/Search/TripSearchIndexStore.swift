//
//  TripSearchIndexStore.swift
//  TravelLog
//

import Foundation
import Observation
import os
import SwiftData

// # Trip search index store
//
// Bridges `Trip` models to the pure search engine (`TripSearchDocument.swift`).
//
// - `TripSearchDocument.make(from:)` snapshots one trip. It reads stored
//   properties and `nonisolated` members only, so it runs on any executor in
//   the caller's own `ModelContext` (the `TripEntityFetcher.entity(from:)`
//   contract). Only values leave it.
// - `TripSearchIndexStore` (MainActor) caches one document per
//   `persistentModelID` (UUID twins are distinct rows, both indexed) and the
//   inverted index over the live list. Stale while revalidate: a store token
//   change keeps serving the cached documents and starts one coalesced
//   off-main rebuild in a fresh `ModelContext`; a cheap scalar fingerprint
//   (name, titles, summary, codes, dates, completion) rebuilds a renamed or
//   resummarized trip on main at once. Main never builds more than
//   `mainThreadBudget` missing or changed documents per call; past that the
//   caller awaits `prepare(_:container:languageTag:)`, which runs the
//   off-main build. The Homes (`TripSearchHome`, read again when the
//   `.home` token moves) are part of the key like the language, so a moved
//   Home rebuilds every document's abroad and domestic facets; a build
//   whose Home read fails publishes nothing. Island sizes
//   (`IslandAreaTable`) and GeoNames regions (`StayAreaTable`) are read
//   off-main by the build; documents built on main before that have none,
//   and the tables' readiness in the key rebuilds them off-main once they
//   are ready.
// - An empty query never reaches the store. The Trips list keeps its
//   `trips -> filters -> sort` pipeline for it, and `search` returns [] for
//   one without building anything.
// - `invalidateAll()` (Delete All Data) drops everything and advances a wipe
//   revision (`wipeRevision`) that an in-flight build must match before it
//   publishes.

extension TripSearchDocument {

    /// Snapshot one trip. Title: `TripSearch.titleAliases`, user-named
    /// when the trip has a custom name. Place: the
    /// `destinationSummary` components plus locality, metro, island and sub
    /// locality of destination and unclassified stays, and in an alternate
    /// field the other-language names (`placeNames`) of their locality,
    /// metro and island, and the sub-locality's own name (`stayAreas`);
    /// island names and names of stays in Japan mark their values
    /// (`TripSearchField.islandValues`, `japanValues`).
    /// Region: their administrative area and, where it differs, their
    /// GeoNames region (`stayAreas`: "Andalusia" for a stay storing the
    /// province "Seville"), and in an alternate field the other-language
    /// names of both and of the island group the stay's GeoNames city lies
    /// in ("Κυκλάδες" for a Cycladic island; for a stay no city lies near, the group
    /// its island or locality name keys). Country:
    /// `TripSearch.countryAliases` of `trip.countryCodes` and their ISO
    /// codes, plus their stored country names. Transit: transit stays'
    /// locality, metro, island and administrative area, never a country, and
    /// in an alternate field the other-language names of their locality,
    /// metro and island (`ヘルシンキ乗り継ぎ`). Home and routine stays are not indexed, and the
    /// persisted `Trip.unknownDestinationSentinel` never is.
    ///
    /// Facets: `island` when a destination or unclassified stay has an island
    /// name and either no metro or an island of `islandTripMinimumAreaKm2` or
    /// more (Crete, Mallorca; a stay in a city on a small island, such as
    /// Manhattan, is a city trip); `abroad` when a destination country is not
    /// a country of `homes` (`homeCountryCodes`), else `domestic`. Without a
    /// Home with a country, or without a country, neither. `flight` when a
    /// stay was reached by a recorded flight or is an airport stop (a trip
    /// that stops at an airport flew), unless both legs at that airport were
    /// recorded as other modes (`isGroundLeg`: driven to it and away);
    /// `longHaul` when it also reaches `longHaulMinimumKm` from home or in
    /// one flight leg. `layover` when an airport stop is a connection
    /// (`isConnection`). `singleCountry` or `multiCountry` by the number of
    /// destination countries. `farthestKm`: the largest `distanceFromHomeKm`
    /// of a destination or unclassified stay (0, never measured, is unknown).
    nonisolated static func make(
        from trip: Trip,
        languageTag: String = AppLanguagePreference.currentTag(),
        calendar: Calendar = TripFilters.yearCalendar,
        normalizer: TripSearchNormalizer? = nil,
        placeNames: TripSearchPlaceNames = .shared,
        homes: [TripSearchHome] = [],
        islandAreaKm2: (String, Double, Double) -> Double? = {
            IslandAreaTable.shared.areaKm2(named: $0, latitude: $1, longitude: $2)
        },
        stayAreas: (Stay) -> StayAreaTable.Areas = {
            StayAreaTable.shared.areas(
                latitude: $0.centroidLatitude, longitude: $0.centroidLongitude, isoCountryCode: $0.isoCountryCode,
                administrativeArea: $0.administrativeArea, subLocality: $0.subLocality)
        }
    ) -> TripSearchDocument {
        func usable(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty, Trip.isUsableDestinationName(trimmed) else { return nil }
            return trimmed
        }

        var place = trip.destinationSummary.split(separator: ",").compactMap { usable(String($0)) }
        var region: [String] = []
        var storedCountries: [String] = []
        var transit: [String] = []
        // Island names, and names of places in Japan (`TripSearchField`).
        var islandNames = Set<String>()
        var japanNames = Set<String>()
        var named: [(name: String, isoCountryCode: String?, layer: PlaceNameTable.Layer)] = []
        var namedTransit: [(name: String, isoCountryCode: String?, layer: PlaceNameTable.Layer)] = []
        var destinationKm: Double?
        var regionNamed: [(name: String, isoCountryCode: String?, layer: PlaceNameTable.Layer)] = []
        var ownNames: [(name: String, of: String)] = []
        var groupNames: [(name: String, of: String)] = []
        var codes = trip.countryCodes.split(separator: ",").map(String.init)
        var facets = Set<TripSearchFacet>()
        // Relationship order differs between contexts; sort so a document
        // built off-main equals the one built on main.
        let stays = (trip.stays ?? []).filter { !$0.isDeleted }.sorted(by: stayOrder)
        var flew = false
        var longestReachKm = 0.0
        for (offset, stay) in stays.enumerated() {
            let next = offset + 1 < stays.count ? stays[offset + 1] : nil
            if stay.transitFromPreviousRaw == TransitMode.flight.rawValue {
                flew = true
                longestReachKm = max(longestReachKm, stay.distanceFromPreviousKm ?? 0)
            }
            if stay.isAirport {
                if !isGroundLeg(stay.transitFromPreviousRaw) || !isGroundLeg(next?.transitFromPreviousRaw) { flew = true }
                if isConnection(at: offset, in: stays) { facets.insert(.layover) }
            }
            switch StayCategory(rawValue: stay.categoryRaw) ?? .unclassified {
            case .destination, .unclassified:
                if let island = usable(stay.islandName),
                   usable(stay.metroName) == nil
                    || (islandAreaKm2(island, stay.centroidLatitude, stay.centroidLongitude) ?? 0)
                    >= islandTripMinimumAreaKm2 {
                    facets.insert(.island)
                }
                let stayPlaces = [stay.locality, stay.metroName, stay.islandName, stay.subLocality].compactMap(usable)
                place += stayPlaces
                if let island = usable(stay.islandName) { islandNames.insert(island) }
                if stay.isoCountryCode?.uppercased() == TripSearchIndex.japan {
                    japanNames.formUnion(stayPlaces + [stay.administrativeArea].compactMap(usable))
                }
                named += [stay.locality, stay.metroName].compactMap(usable).map { ($0, stay.isoCountryCode, .city) }
                named += [stay.islandName].compactMap(usable).map { ($0, stay.isoCountryCode, .island) }
                longestReachKm = max(longestReachKm, stay.distanceFromHomeKm)
                if stay.distanceFromHomeKm > 0 { destinationKm = max(destinationKm ?? 0, stay.distanceFromHomeKm) }
                let areas = stayAreas(stay)
                let area = usable(stay.administrativeArea)
                if let area {
                    region.append(area)
                    regionNamed.append((area, stay.isoCountryCode, .region))
                }
                if let derived = Self.derivedRegion(areas, storedArea: area) {
                    region.append(derived)
                    regionNamed.append((derived, stay.isoCountryCode, .region))
                    if stay.isoCountryCode?.uppercased() == TripSearchIndex.japan { japanNames.insert(derived) }
                }
                // The island group of the city the coordinate lies by; by
                // stored name only for a stay no city lies near.
                let groupSource = [stay.islandName, stay.locality, area].lazy.compactMap(usable).first
                if let id = areas.cityGeonameID, let groupSource {
                    groupNames += placeNames.names(for: String(id), isoCountryCode: stay.isoCountryCode, layer: .group)
                        .map { ($0, groupSource) }
                } else if areas.cityGeonameID == nil {
                    regionNamed += [stay.islandName, stay.locality].compactMap(usable)
                        .map { ($0, stay.isoCountryCode, .group) }
                }
                if let subLocality = usable(stay.subLocality), let own = areas.subLocalityName {
                    ownNames += TripSearchPlaceNames.searchNames(stored: [:], extras: Self.ownNames(own))
                        .map { ($0, subLocality) }
                }
                if let code = stay.isoCountryCode { codes.append(code) }
                if let country = usable(stay.country) { storedCountries.append(country) }
            case .transit:
                let stayPlaces = [stay.locality, stay.metroName, stay.islandName, stay.administrativeArea]
                    .compactMap(usable)
                transit += stayPlaces
                if let island = usable(stay.islandName) { islandNames.insert(island) }
                if stay.isoCountryCode?.uppercased() == TripSearchIndex.japan { japanNames.formUnion(stayPlaces) }
                namedTransit += [stay.locality, stay.metroName].compactMap(usable).map { ($0, stay.isoCountryCode, .city) }
                namedTransit += [stay.islandName].compactMap(usable).map { ($0, stay.isoCountryCode, .island) }
            case .home, .routine:
                continue
            }
        }

        var seenCodes = Set<String>()
        let uniqueCodes = codes.compactMap { raw -> String? in
            let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !code.isEmpty, seenCodes.insert(code).inserted else { return nil }
            return code
        }
        let home = homeCountryCodes(at: trip.startDate, homes: homes)
        if !home.isEmpty, !seenCodes.isEmpty {
            facets.insert(seenCodes.isSubset(of: home) ? .domestic : .abroad)
        }
        if flew {
            facets.insert(.flight)
            if longestReachKm >= longHaulMinimumKm { facets.insert(.longHaul) }
        }
        if !seenCodes.isEmpty { facets.insert(seenCodes.count == 1 ? .singleCountry : .multiCountry) }
        let start = calendar.dateComponents([.year, .month], from: trip.startDate)
        return TripSearchDocument(
            tripID: trip.id,
            fields: [
                TripSearchField(
                    kind: .title, displayValues: TripSearch.titleAliases(for: trip, languageTag: languageTag),
                    isUserNamed: TripTitleStore.normalized(trip.customName) != nil),
                TripSearchField(
                    kind: .place, displayValues: place, islandValues: islandNames, japanValues: japanNames),
                TripSearchField(kind: .region, displayValues: region, japanValues: japanNames),
                TripSearchField(
                    kind: .country,
                    displayValues: TripSearch.countryAliases(for: uniqueCodes, languageTag: languageTag) + storedCountries),
                TripSearchField(
                    kind: .date,
                    displayValues: dateWords(
                        start: trip.startDate, end: trip.endDate, languageTag: languageTag, calendar: calendar)),
                TripSearchField(
                    kind: .transit, displayValues: transit, islandValues: islandNames, japanValues: japanNames),
                .alternatePlaceNames(of: named, placeNames: placeNames, adding: ownNames),
                .alternatePlaceNames(of: namedTransit, placeNames: placeNames, kind: .transit),
                .alternatePlaceNames(of: regionNamed, placeNames: placeNames, adding: groupNames, kind: .region),
            ],
            startDate: trip.startDate,
            endDate: trip.endDate,
            startYear: start.year ?? 0,
            startMonth: start.month ?? 0,
            durationDays: trip.durationDays,
            isComplete: trip.isComplete,
            countryCodes: seenCodes,
            facets: facets,
            farthestKm: destinationKm,
            normalizer: normalizer)
    }

    /// A stay's GeoNames region (`StayAreaTable`) when it is not its stored
    /// administrative area.
    nonisolated static func derivedRegion(_ areas: StayAreaTable.Areas, storedArea: String?) -> String? {
        guard let region = areas.region?.trimmingCharacters(in: .whitespacesAndNewlines), !region.isEmpty,
              storedArea.map({ TripTitleStore.normalizedPlaceName($0) != TripTitleStore.normalizedPlaceName(region) })
                ?? true else { return nil }
        return region
    }

    /// A neighbourhood's own name, and that name without the block number
    /// Japanese and Korean addresses append to a district (渋谷一丁目 →
    /// 渋谷, 종로1가 → 종로), which is the name people type.
    nonisolated static func ownNames(_ name: String) -> [String] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let block = trimmed.range(
            of: "([0-9０-９]+|[〇一二三四五六七八九十]+)(丁目|가)$", options: .regularExpression) else { return [trimmed] }
        let stem = String(trimmed[..<block.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return stem.count >= 2 ? [trimmed, stem] : [trimmed]
    }

    /// A flight trip this far from home (a destination stay) or with a
    /// flight leg this long is long-haul: the usual airline and Eurocontrol
    /// threshold sits between 3,000 and 4,800 km; 4,000 km keeps Europe to
    /// the Canaries or the Gulf medium-haul and transatlantic flights long-haul.
    nonisolated static let longHaulMinimumKm = 4_000.0

    /// An island this large is an island trip even with a metro on it.
    nonisolated static let islandTripMinimumAreaKm2 = 500.0

    /// Whether the airport stop at `index` of the trip's ordered `stays` is
    /// a connection: a flight on the journey that reached it and on the one
    /// that left it. A journey runs from one anchor to the next through brief
    /// waypoints, and its flight sits on its first stay after the origin,
    /// possibly a waypoint before the airport (`FlightJudge`). The anchors
    /// follow `FlightJudge.isAnchor` over the values a trip keeps: an
    /// airport, a destination, a stop of `connectionAnchorDwellSeconds` or
    /// more, or one followed by `connectionAnchorSilenceSeconds` without a
    /// stay. Like the judge, the end clustering ran into the silence after
    /// a stop (at most the gap left, `connectionStayExtensionCapSeconds` and
    /// the stop's stored length) counts as silence, not dwell. The judge's
    /// airborne exception for a fix seen mid-flight needs coordinates and
    /// speeds, and is left out. The stop is reached by a
    /// flight marked on it or on the waypoints right before it, and left by
    /// one marked on the stays after it up to the next anchor. The flight
    /// home is no stay, so a stop that ends the trip is no connection.
    nonisolated static func isConnection(at index: Int, in stays: [Stay]) -> Bool {
        func isFlight(_ stay: Stay) -> Bool { stay.transitFromPreviousRaw == TransitMode.flight.rawValue }
        func isAnchor(_ position: Int) -> Bool {
            let stay = stays[position]
            guard !stay.isAirport, stay.categoryRaw == StayCategory.transit.rawValue else { return true }
            guard position + 1 < stays.count else { return true }
            let stored = stay.endTime.timeIntervalSince(stay.startTime)
            let gap = stays[position + 1].startTime.timeIntervalSince(stay.endTime)
            let stretch = max(0, min(gap, connectionStayExtensionCapSeconds, stored))
            return stored - stretch >= connectionAnchorDwellSeconds
                || gap + stretch >= connectionAnchorSilenceSeconds
        }
        var reached = false
        for position in stride(from: index, through: 0, by: -1) {
            if position < index, isAnchor(position) { break }
            if isFlight(stays[position]) { reached = true; break }
        }
        guard reached else { return false }
        for position in stays.indices where position > index {
            if isFlight(stays[position]) { return true }
            if isAnchor(position) { return false }
        }
        return false
    }

    /// `FlightJudge.anchorDwellSeconds`, `anchorSilenceSeconds` and
    /// `stayExtensionCapSeconds` (the judge is not a search dependency): a
    /// stop this long, or followed by this long without a stay, ends a
    /// journey; clustering runs a stop's end at most this far into silence.
    nonisolated static let connectionAnchorDwellSeconds: TimeInterval = 20 * 60
    nonisolated static let connectionAnchorSilenceSeconds: TimeInterval = 2 * 3600
    nonisolated static let connectionStayExtensionCapSeconds: TimeInterval = 12 * 3600

    /// A leg recorded as a mode other than a flight: a ground mode, or the
    /// user's "not a flight" (`TransitMode`). Nil (not inferred yet) and
    /// `unknown` (no flight found, nothing ruled out) record no mode.
    nonisolated static func isGroundLeg(_ raw: String?) -> Bool {
        guard let raw else { return false }
        return raw != TransitMode.flight.rawValue && raw != TransitMode.unknown.rawValue
    }

    /// The countries of the Homes lived in on `date`; for a date no Home
    /// covers (trips from before the first Home was set up), every Home's.
    nonisolated static func homeCountryCodes(at date: Date, homes: [TripSearchHome]) -> Set<String> {
        let active = homes.filter { $0.startedAt <= date && ($0.endedAt.map { date < $0 } ?? true) }
        return Set((active.isEmpty ? homes : active).map(\.isoCountryCode))
    }

    private nonisolated static func stayOrder(_ a: Stay, _ b: Stay) -> Bool {
        let orderA = a.orderInTrip ?? .max
        let orderB = b.orderInTrip ?? .max
        if orderA != orderB { return orderA < orderB }
        if a.startTime != b.startTime { return a.startTime < b.startTime }
        return a.id.uuidString < b.id.uuidString
    }
}

/// The `Trip` scalars a document depends on that can be read without
/// faulting stays or title variants. A mismatch rebuilds that one document
/// immediately (rename, summary change); stay and variant edits arrive
/// through the store token and the off-main rebuild instead.
nonisolated struct TripSearchFingerprint: Sendable, Equatable {
    let customName: String?
    let aiGeneratedTitle: String?
    let titleSourceRevision: UUID?
    let destinationSummary: String
    let countryCodes: String
    let startDate: Date
    let endDate: Date?
    let isComplete: Bool

    init(_ trip: Trip) {
        customName = trip.customName
        aiGeneratedTitle = trip.aiGeneratedTitle
        titleSourceRevision = trip.titleSourceRevision
        destinationSummary = trip.destinationSummary
        countryCodes = trip.countryCodes
        startDate = trip.startDate
        endDate = trip.endDate
        isComplete = trip.isComplete
    }
}

extension TripSearchHome {

    /// Every Home with a country, in a fixed order (nil when the read fails).
    nonisolated static func fetch(in context: ModelContext) -> [TripSearchHome]? {
        try? fetchAll(in: context)
    }

    /// Every Home with a country, in a fixed order; a failed read throws.
    nonisolated static func fetchAll(in context: ModelContext) throws -> [TripSearchHome] {
        try context.fetch(FetchDescriptor<Home>()).compactMap { home -> TripSearchHome? in
            guard let code = TripTitleStore.homeCountryCode(home.isoCountryCode) else { return nil }
            return TripSearchHome(isoCountryCode: code, startedAt: home.startedAt, endedAt: home.endedAt)
        }
        .sorted { ($0.startedAt, $0.isoCountryCode) < ($1.startedAt, $1.isoCountryCode) }
    }
}

/// One document built off-main, keyed by its row.
nonisolated struct TripSearchBuiltDocument: Sendable {
    let id: PersistentIdentifier
    let fingerprint: TripSearchFingerprint
    let document: TripSearchDocument
}

/// Off-main builder: its own `ModelContext`, stays and title variants
/// prefetched, values out.
nonisolated enum TripSearchIndexBuilder {

    @concurrent
    static func build(
        container: ModelContainer,
        languageTag: String,
        calendar: Calendar
    ) async -> [TripSearchBuiltDocument]? {
        buildDocuments(container: container, languageTag: languageTag, calendar: calendar)
    }

    /// Nil when the trip or Home fetch fails or the task is cancelled
    /// (checked every 100 trips). Reads island sizes and region names first
    /// (`IslandAreaTable.prepare()`, `StayAreaTable.prepare()`).
    static func buildDocuments(
        container: ModelContainer,
        languageTag: String,
        calendar: Calendar
    ) -> [TripSearchBuiltDocument]? {
        TripSearch.prewarmVocabulary(languageTag: languageTag)
        TripQueryParser.prewarm(languageTag: languageTag)
        IslandAreaTable.shared.prepare()
        StayAreaTable.shared.prepare()
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<Trip>(
            sortBy: [SortDescriptor(\Trip.startDate, order: .reverse)])
        descriptor.relationshipKeyPathsForPrefetching = [\.stays, \.localizedTitles]
        // Without its Homes a build would publish documents lacking the
        // abroad and domestic facets under a key that claims them.
        guard let trips = try? context.fetch(descriptor),
              let homes = TripSearchHome.fetch(in: context) else { return nil }
        let normalizer = TripSearchNormalizer()
        var built: [TripSearchBuiltDocument] = []
        built.reserveCapacity(trips.count)
        for (offset, trip) in trips.enumerated() {
            if offset % 100 == 0, Task.isCancelled { return nil }
            built.append(TripSearchBuiltDocument(
                id: trip.persistentModelID,
                fingerprint: TripSearchFingerprint(trip),
                document: .make(
                    from: trip, languageTag: languageTag, calendar: calendar, normalizer: normalizer, homes: homes)))
        }
        return built
    }
}

/// Index and its aligned live trips: `trips[i]` produced `index.documents[i]`.
struct IndexedTrips {
    let index: TripSearchIndex
    let trips: [Trip]
}

/// One `searchResult` answer: the live matches and the index they came from
/// (for the spelling suggestion), so a recompute surveys the rows once.
struct TripSearchResult {
    let matches: [(trip: Trip, match: TripSearchMatch)]
    let index: TripSearchIndex
}

private nonisolated struct TripSearchIndexKey: Equatable, Sendable {
    let storeToken: Int
    let languageTag: String
    let timeZoneIdentifier: String
    /// The Homes' countries decide the abroad and domestic facets.
    let homes: [TripSearchHome]
    /// Whether island sizes and stay areas were readable
    /// (`IslandAreaTable.isPrepared`, `StayAreaTable.isPrepared`):
    /// documents built before have no island facet from a city's island
    /// and no GeoNames region.
    let geographyReady: Bool

    /// The key of an off-main build, which reads island sizes first.
    var withGeographyReady: TripSearchIndexKey {
        TripSearchIndexKey(
            storeToken: storeToken, languageTag: languageTag, timeZoneIdentifier: timeZoneIdentifier,
            homes: homes, geographyReady: true)
    }
}

private nonisolated struct TripSearchCacheEntry {
    let document: TripSearchDocument
    let fingerprint: TripSearchFingerprint
    let key: TripSearchIndexKey
    /// `cacheRevision` at write; a build keeps entries written after it started.
    let stamp: UInt64
}

private nonisolated struct TripSearchMemoKey: Equatable {
    let query: String
    let allowsTrailingPartial: Bool
    let languageTag: String
    let indexGeneration: UInt64
    /// Relative dates ("last year") move at local midnight and with the zone.
    let day: Int
    let timeZoneIdentifier: String
}

/// Per-row document cache and inverted index for the Trips list search.
/// Call it only for a non-empty query. Read `generation` (observable) in the
/// recompute key while searching: it advances when an off-main build
/// publishes or the cache is dropped, never during `search` itself.
@MainActor
@Observable
final class TripSearchIndexStore {

    static let shared = TripSearchIndexStore(tracker: .shared, builder: TripSearchIndexStore.defaultBuilder)

    /// Most documents one call builds synchronously on main. A row the list
    /// never rendered faults its stays and title variants: about 2.3 ms per
    /// document on an M4 (0.3 ms warm), so bulk changes go off-main.
    nonisolated static let mainThreadBudget = 8

    typealias Builder = @Sendable (ModelContainer, String, Calendar) async -> [TripSearchBuiltDocument]?

    nonisolated static let defaultBuilder: Builder = { container, languageTag, calendar in
        await TripSearchIndexBuilder.build(container: container, languageTag: languageTag, calendar: calendar)
    }

    /// Advances when an off-main build publishes or `invalidateAll()` runs.
    private(set) var generation = 0

    /// Advances only when `invalidateAll()` runs, so a reader can tell a
    /// revocation from an ordinary publish. An in-flight build must match it
    /// to publish.
    @ObservationIgnored private(set) var wipeRevision = 0

    @ObservationIgnored private let tracker: StoreChangeTracker
    @ObservationIgnored private let builder: Builder
    /// `IslandAreaTable.shared.isPrepared` and `StayAreaTable.shared.isPrepared`
    /// (a constant in tests, which run in parallel with builds that prepare
    /// the shared tables).
    @ObservationIgnored private let geographyReady: @Sendable () -> Bool
    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var cache: [PersistentIdentifier: TripSearchCacheEntry] = [:]
    @ObservationIgnored private var cacheRevision: UInt64 = 0
    @ObservationIgnored private var index: TripSearchIndex?
    @ObservationIgnored private var indexIDs: [PersistentIdentifier] = []
    @ObservationIgnored private var indexRevision: UInt64 = 0
    @ObservationIgnored private var memo: (key: TripSearchMemoKey, matches: [TripSearchMatch])?
    @ObservationIgnored private var buildTask: Task<Void, Never>?
    @ObservationIgnored private var buildKey: TripSearchIndexKey?
    @ObservationIgnored private var buildSerial = 0
    @ObservationIgnored private var rerunRequested = false
    /// The Homes as of a `.home` store token (`currentHomes`).
    @ObservationIgnored private var homesCache: (token: Int, homes: [TripSearchHome])?
    #if DEBUG
    @ObservationIgnored private var latestBuild: Task<Void, Never>?
    @ObservationIgnored private(set) var synchronousBuildCount = 0
    #endif

    private init(
        tracker: StoreChangeTracker,
        builder: @escaping Builder,
        geographyReady: @escaping @Sendable () -> Bool = {
            IslandAreaTable.shared.isPrepared && StayAreaTable.shared.isPrepared
        }
    ) {
        self.tracker = tracker
        self.builder = builder
        self.geographyReady = geographyReady
    }

    #if DEBUG
    /// Test-only: an isolated store over an isolated tracker, so tests never
    /// bump `StoreChangeTracker.shared` or share `shared`'s cache.
    convenience init(
        forTesting tracker: StoreChangeTracker,
        builder: Builder? = nil,
        geographyReady: (@Sendable () -> Bool)? = nil
    ) {
        self.init(tracker: tracker, builder: builder ?? Self.defaultBuilder, geographyReady: geographyReady ?? { true })
    }
    #endif

    // MARK: - Queries

    /// Resolver results for the live, non-deleted `trips`, each with its
    /// match. Nil when more than `mainThreadBudget` documents are missing or
    /// changed: await `prepare` first (an off-main build is already
    /// scheduled). A memo keyed by (query, trailing partial, language, index
    /// generation, local day and zone) makes repeated identical calls free.
    /// An empty query returns []. `now` is the instant relative dates read.
    func search(
        _ trips: [Trip],
        query: String,
        allowsTrailingPartial: Bool,
        languageTag: String = AppLanguagePreference.currentTag(),
        now: Date = .now
    ) -> [(trip: Trip, match: TripSearchMatch)]? {
        searchResult(
            trips, query: query, allowsTrailingPartial: allowsTrailingPartial, languageTag: languageTag, now: now)?
            .matches
    }

    /// `search` plus the index it searched, from one survey of `trips`. An
    /// empty query returns no matches with the current index (or an empty
    /// one) and builds nothing. The memo day and the resolver read the same
    /// `now` in the same calendar, so a call that straddles midnight cannot
    /// file one day's results under the other.
    func searchResult(
        _ trips: [Trip],
        query: String,
        allowsTrailingPartial: Bool,
        languageTag: String = AppLanguagePreference.currentTag(),
        now: Date = .now
    ) -> TripSearchResult? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return TripSearchResult(matches: [], index: index ?? TripSearchIndex(documents: []))
        }
        guard let indexed = indexedTrips(trips, languageTag: languageTag) else { return nil }
        let calendar = TripFilters.yearCalendar
        let key = TripSearchMemoKey(
            query: trimmed,
            allowsTrailingPartial: allowsTrailingPartial,
            languageTag: languageTag,
            indexGeneration: indexed.index.generation,
            day: Self.memoDay(now, calendar: calendar),
            timeZoneIdentifier: calendar.timeZone.identifier)
        let matches: [TripSearchMatch]
        if let memo, memo.key == key {
            matches = memo.matches
        } else {
            matches = TripQueryParser.searchTrips(
                index: indexed.index,
                query: trimmed,
                allowsTrailingPartial: allowsTrailingPartial,
                now: now,
                calendar: calendar,
                languageTag: languageTag)
            memo = (key, matches)
        }
        let live: [(trip: Trip, match: TripSearchMatch)] = matches.compactMap { match in
            guard indexed.trips.indices.contains(match.documentIndex) else { return nil }
            let trip = indexed.trips[match.documentIndex]
            guard !trip.isDeleted else { return nil }
            return (trip, match)
        }
        return TripSearchResult(matches: live, index: indexed.index)
    }

    /// The memo's day: the resolver reads relative dates ("this year") in
    /// `calendar`, so the memo turns over at that calendar's midnight.
    /// (`ordinality(of: .day, in: .era)` counts UTC days, so it is not used.)
    nonisolated static func memoDay(_ now: Date = .now, calendar: Calendar = TripFilters.yearCalendar) -> Int {
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        return (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
    }

    /// The index over the live, non-deleted `trips` (for the spelling
    /// suggestion and other index readers). Builds at most
    /// `mainThreadBudget` missing or changed documents on main, serves
    /// documents from an earlier store token while one off-main rebuild
    /// runs, and rebuilds the inverted index only when an aligned document
    /// changed. Nil when more documents are missing or changed than the
    /// budget allows.
    func indexedTrips(
        _ trips: [Trip],
        languageTag: String = AppLanguagePreference.currentTag()
    ) -> IndexedTrips? {
        let key = currentKey(languageTag, trips: trips)
        let survey = survey(trips, key: key)
        guard !survey.exceedsBudget else {
            scheduleRebuild(key: key, from: trips)
            return nil
        }
        let positions = survey.missing + survey.changed
        if !positions.isEmpty {
            let normalizer = TripSearchNormalizer()
            for position in positions {
                store(survey.trips[position], id: survey.ids[position],
                      fingerprint: survey.fingerprints[position], key: key, normalizer: normalizer)
            }
        }
        if survey.hasStale { scheduleRebuild(key: key, from: trips) }

        if let index, indexIDs == survey.ids, indexRevision == cacheRevision {
            return IndexedTrips(index: index, trips: survey.trips)
        }
        let documents = survey.ids.compactMap { cache[$0]?.document }
        guard documents.count == survey.ids.count else { return nil }
        let rebuilt = TripSearchIndex(documents: documents)
        index = rebuilt
        indexIDs = survey.ids
        indexRevision = cacheRevision
        return IndexedTrips(index: rebuilt, trips: survey.trips)
    }

    #if DEBUG
    /// True when `search` would return nil for `trips` right now.
    func needsPreparation(
        _ trips: [Trip],
        languageTag: String = AppLanguagePreference.currentTag()
    ) -> Bool {
        survey(trips, key: currentKey(languageTag, trips: trips)).exceedsBudget
    }
    #endif

    /// Makes `search` answer without a large main-thread build. Returns at
    /// once when no document is missing and the changed ones fit the budget.
    /// Otherwise it runs (or joins) the off-main build and any follow-up it
    /// queued (plus one more when only a build that was already running
    /// finished and too many rows still differ), then builds on main, one
    /// budget per turn, the rows the background context could not see
    /// (unsaved inserts and edits).
    /// `container` defaults to the trips' own.
    func prepare(
        _ trips: [Trip],
        container: ModelContainer? = nil,
        languageTag: String = AppLanguagePreference.currentTag()
    ) async {
        if let container { self.container = container }
        let initial = survey(trips, key: currentKey(languageTag, trips: trips))
        // Small libraries build off-main too, so the first keystroke finds them cached.
        guard !initial.missing.isEmpty || initial.exceedsBudget else { return }
        let wipe = wipeRevision
        let entrySerial = buildSerial
        scheduleRebuild(key: currentKey(languageTag, trips: trips), from: trips)
        await awaitBuilds(wipe: wipe)
        // Only a build already in flight on entry ran, and it may have
        // fetched before rows saved since (a remote merge ahead of its
        // tracker bump, same key). One follow-up build can see them.
        if !Task.isCancelled, wipe == wipeRevision, buildTask == nil, buildSerial == entrySerial,
           survey(trips, key: currentKey(languageTag, trips: trips)).exceedsBudget {
            scheduleRebuild(key: currentKey(languageTag, trips: trips), from: trips)
            await awaitBuilds(wipe: wipe)
        }
        while !Task.isCancelled, wipe == wipeRevision {
            let key = currentKey(languageTag, trips: trips)
            let survey = survey(trips, key: key)
            guard !survey.missing.isEmpty || survey.exceedsBudget else { return }
            let normalizer = TripSearchNormalizer()
            for position in (survey.missing + survey.changed).prefix(Self.mainThreadBudget) {
                store(survey.trips[position], id: survey.ids[position],
                      fingerprint: survey.fingerprints[position], key: key, normalizer: normalizer)
            }
            await Task.yield()
        }
    }

    /// Awaits the in-flight build and any follow-up it starts.
    private func awaitBuilds(wipe: Int) async {
        while let task = buildTask, !Task.isCancelled, wipe == wipeRevision {
            await task.value
            if buildTask == task { break }  // Never spin on a finished build.
        }
    }

    /// Drops every document, the index and the memo, clears
    /// `TripSearch.normalizedFormsCache`, the place-name memo
    /// (`TripSearchPlaceNames`) and the stay-area memo (`StayAreaTable`),
    /// and revokes any in-flight build
    /// (Delete All Data: deletion revokes queued work as well as stored content).
    func invalidateAll() {
        wipeRevision += 1
        buildSerial += 1
        buildTask?.cancel()
        buildTask = nil
        buildKey = nil
        rerunRequested = false
        cache.removeAll()
        cacheRevision &+= 1
        index = nil
        indexIDs = []
        memo = nil
        homesCache = nil
        TripSearch.normalizedFormsCache.withLock { $0.removeAll() }
        TripSearchPlaceNames.shared.removeAll()
        StayAreaTable.shared.removeAll()
        generation += 1
    }

    // MARK: - Cache

    private struct Survey {
        var trips: [Trip] = []
        var ids: [PersistentIdentifier] = []
        var fingerprints: [TripSearchFingerprint] = []
        /// Positions without a document in this language.
        var missing: [Int] = []
        /// Positions whose fingerprint no longer matches.
        var changed: [Int] = []
        /// Some document predates the current key.
        var hasStale = false

        /// More rows to build than one call may build on main.
        var exceedsBudget: Bool { missing.count + changed.count > TripSearchIndexStore.mainThreadBudget }
    }

    private func survey(_ trips: [Trip], key: TripSearchIndexKey) -> Survey {
        var survey = Survey()
        survey.trips.reserveCapacity(trips.count)
        survey.ids.reserveCapacity(trips.count)
        survey.fingerprints.reserveCapacity(trips.count)
        for trip in trips where !trip.isDeleted {
            let id = trip.persistentModelID
            let fingerprint = TripSearchFingerprint(trip)
            let position = survey.trips.count
            if let entry = cache[id], entry.key.languageTag == key.languageTag {
                if entry.fingerprint != fingerprint {
                    survey.changed.append(position)
                } else if entry.key != key {
                    survey.hasStale = true
                }
            } else {
                survey.missing.append(position)
            }
            survey.trips.append(trip)
            survey.ids.append(id)
            survey.fingerprints.append(fingerprint)
        }
        return survey
    }

    private func store(
        _ trip: Trip,
        id: PersistentIdentifier,
        fingerprint: TripSearchFingerprint,
        key: TripSearchIndexKey,
        normalizer: TripSearchNormalizer
    ) {
        cacheRevision &+= 1
        cache[id] = TripSearchCacheEntry(
            document: .make(from: trip, languageTag: key.languageTag, normalizer: normalizer, homes: key.homes),
            fingerprint: fingerprint,
            key: key,
            stamp: cacheRevision)
        #if DEBUG
        synchronousBuildCount += 1
        #endif
    }

    private func currentKey(_ languageTag: String, trips: [Trip]) -> TripSearchIndexKey {
        TripSearchIndexKey(
            storeToken: tracker.token(for: [.trip, .stay]),
            languageTag: languageTag,
            timeZoneIdentifier: TimeZone.current.identifier,
            homes: currentHomes(trips),
            geographyReady: geographyReady())
    }

    /// The Homes, read again only when the `.home` store token moves (a
    /// Home added, moved or removed), so a Home change rebuilds the index
    /// like a language change. A failed read is not cached.
    private func currentHomes(_ trips: [Trip]) -> [TripSearchHome] {
        let token = tracker.token(for: .home)
        if let homesCache, homesCache.token == token { return homesCache.homes }
        guard let context = trips.lazy.compactMap({ $0.modelContext }).first ?? container?.mainContext,
              let homes = TripSearchHome.fetch(in: context) else { return homesCache?.homes ?? [] }
        homesCache = (token, homes)
        return homes
    }

    // MARK: - Off-main rebuild

    /// One build in flight; a request for a different key while it runs
    /// queues exactly one follow-up.
    private func scheduleRebuild(key: TripSearchIndexKey, from trips: [Trip]) {
        let key = key.withGeographyReady
        if buildTask != nil {
            if buildKey != key { rerunRequested = true }
            return
        }
        guard let container = container ?? trips.lazy.compactMap({ $0.modelContext?.container }).first
        else { return }
        self.container = container
        startBuild(key: key, container: container)
    }

    private func startBuild(key: TripSearchIndexKey, container: ModelContainer) {
        let key = key.withGeographyReady
        buildSerial += 1
        let serial = buildSerial
        let wipe = wipeRevision
        let startRevision = cacheRevision
        let builder = builder
        let calendar = TripFilters.yearCalendar
        buildKey = key
        rerunRequested = false
        let task = Task(priority: .utility) { [weak self] in
            let built = await builder(container, key.languageTag, calendar)
            self?.finishBuild(built, key: key, serial: serial, wipe: wipe, startRevision: startRevision)
        }
        buildTask = task
        #if DEBUG
        latestBuild = task
        #endif
    }

    /// Publishes a finished build unless it was revoked. Entries written on
    /// main after it started are fresher and win; rows it did not see and
    /// nothing rewrote since (deleted trips) are dropped. A build that
    /// reproduces every cached document only restamps the entries' key and
    /// fingerprint, keeping the index, memo and `generation`. Rows built on
    /// main before island sizes were ready get one follow-up build after a
    /// build that succeeded.
    private func finishBuild(
        _ built: [TripSearchBuiltDocument]?,
        key: TripSearchIndexKey,
        serial: Int,
        wipe: Int,
        startRevision: UInt64
    ) {
        guard serial == buildSerial, wipe == wipeRevision else { return }
        buildTask = nil
        buildKey = nil
        let rerun = rerunRequested
        rerunRequested = false
        if let built {
            let unchanged = built.count == cache.count && built.allSatisfy { item in
                guard let entry = cache[item.id] else { return false }
                return entry.stamp > startRevision || entry.document == item.document
            }
            if unchanged {
                for item in built {
                    guard let entry = cache[item.id], entry.stamp <= startRevision else { continue }
                    cache[item.id] = TripSearchCacheEntry(
                        document: entry.document, fingerprint: item.fingerprint, key: key, stamp: entry.stamp)
                }
            } else {
                cacheRevision &+= 1
                var next: [PersistentIdentifier: TripSearchCacheEntry] = [:]
                next.reserveCapacity(built.count)
                for item in built {
                    next[item.id] = TripSearchCacheEntry(
                        document: item.document, fingerprint: item.fingerprint, key: key, stamp: cacheRevision)
                }
                for (id, entry) in cache where entry.stamp > startRevision {
                    next[id] = entry
                }
                cache = next
                generation += 1
            }
        }
        // Rows built on main before island sizes were ready (newer than this
        // build, so they won) lack the island facet: one follow-up rebuilds
        // them. Only after a build that read its rows: a failed read is
        // retried by the next ordinary trigger, never in a loop.
        let islandFollowUp = built != nil && geographyReady()
            && cache.values.contains { !$0.key.geographyReady }
        if rerun || islandFollowUp, let container {
            startBuild(key: currentKey(key.languageTag, trips: []), container: container)
        }
    }

    #if DEBUG
    var cachedDocumentCount: Int { cache.count }
    var hasPendingBuild: Bool { buildTask != nil }

    /// Awaits the most recently started build, revoked or not.
    func waitForBuildForTesting() async {
        await latestBuild?.value
    }
    #endif
}
