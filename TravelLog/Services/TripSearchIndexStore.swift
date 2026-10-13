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
//   off-main build.
// - An empty query never reaches the store. The Trips list keeps its
//   `trips -> filters -> sort` pipeline for it, and `search` returns [] for
//   one without building anything.
// - `invalidateAll()` (Delete All Data) drops everything and advances a wipe
//   revision (`wipeRevision`) that an in-flight build must match before it
//   publishes.

extension TripSearchDocument {

    /// Snapshot one trip. Title: `TripSearch.titleAliases`. Place: the
    /// `destinationSummary` components plus locality, metro, island and sub
    /// locality of destination and unclassified stays. Region: their
    /// administrative area. Country: `TripSearch.countryAliases` of
    /// `trip.countryCodes` and their ISO codes, plus their stored country
    /// names. Transit: transit stays' locality, metro and administrative
    /// area, never a country. Home and routine stays are not indexed, and the
    /// persisted `Trip.unknownDestinationSentinel` never is.
    nonisolated static func make(
        from trip: Trip,
        languageTag: String = AppLanguagePreference.currentTag(),
        calendar: Calendar = TripFilters.yearCalendar,
        normalizer: TripSearchNormalizer? = nil
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
        var codes = trip.countryCodes.split(separator: ",").map(String.init)
        // Relationship order differs between contexts; sort so a document
        // built off-main equals the one built on main.
        let stays = (trip.stays ?? []).filter { !$0.isDeleted }.sorted(by: stayOrder)
        for stay in stays {
            switch StayCategory(rawValue: stay.categoryRaw) ?? .unclassified {
            case .destination, .unclassified:
                place += [stay.locality, stay.metroName, stay.islandName, stay.subLocality].compactMap(usable)
                if let area = usable(stay.administrativeArea) { region.append(area) }
                if let code = stay.isoCountryCode { codes.append(code) }
                if let country = usable(stay.country) { storedCountries.append(country) }
            case .transit:
                transit += [stay.locality, stay.metroName, stay.administrativeArea].compactMap(usable)
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
        let start = calendar.dateComponents([.year, .month], from: trip.startDate)
        return TripSearchDocument(
            tripID: trip.id,
            fields: [
                TripSearchField(kind: .title, displayValues: TripSearch.titleAliases(for: trip, languageTag: languageTag)),
                TripSearchField(kind: .place, displayValues: place),
                TripSearchField(kind: .region, displayValues: region),
                TripSearchField(
                    kind: .country,
                    displayValues: TripSearch.countryAliases(for: uniqueCodes, languageTag: languageTag) + storedCountries),
                TripSearchField(
                    kind: .date,
                    displayValues: dateWords(
                        start: trip.startDate, end: trip.endDate, languageTag: languageTag, calendar: calendar)),
                TripSearchField(kind: .transit, displayValues: transit),
            ],
            startDate: trip.startDate,
            endDate: trip.endDate,
            startYear: start.year ?? 0,
            startMonth: start.month ?? 0,
            durationDays: trip.durationDays,
            isComplete: trip.isComplete,
            countryCodes: seenCodes,
            normalizer: normalizer)
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

    /// Nil when the fetch fails or the task is cancelled (checked every 100 trips).
    static func buildDocuments(
        container: ModelContainer,
        languageTag: String,
        calendar: Calendar
    ) -> [TripSearchBuiltDocument]? {
        TripSearch.prewarmVocabulary(languageTag: languageTag)
        TripQueryParser.prewarm(languageTag: languageTag)
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<Trip>(
            sortBy: [SortDescriptor(\Trip.startDate, order: .reverse)])
        descriptor.relationshipKeyPathsForPrefetching = [\.stays, \.localizedTitles]
        guard let trips = try? context.fetch(descriptor) else { return nil }
        let normalizer = TripSearchNormalizer()
        var built: [TripSearchBuiltDocument] = []
        built.reserveCapacity(trips.count)
        for (offset, trip) in trips.enumerated() {
            if offset % 100 == 0, Task.isCancelled { return nil }
            built.append(TripSearchBuiltDocument(
                id: trip.persistentModelID,
                fingerprint: TripSearchFingerprint(trip),
                document: .make(from: trip, languageTag: languageTag, calendar: calendar, normalizer: normalizer)))
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
    #if DEBUG
    @ObservationIgnored private var latestBuild: Task<Void, Never>?
    @ObservationIgnored private(set) var synchronousBuildCount = 0
    #endif

    private init(tracker: StoreChangeTracker, builder: @escaping Builder) {
        self.tracker = tracker
        self.builder = builder
    }

    #if DEBUG
    /// Test-only: an isolated store over an isolated tracker, so tests never
    /// bump `StoreChangeTracker.shared` or share `shared`'s cache.
    convenience init(forTesting tracker: StoreChangeTracker, builder: Builder? = nil) {
        self.init(tracker: tracker, builder: builder ?? Self.defaultBuilder)
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
        let key = currentKey(languageTag)
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

    /// True when `search` would return nil for `trips` right now.
    func needsPreparation(
        _ trips: [Trip],
        languageTag: String = AppLanguagePreference.currentTag()
    ) -> Bool {
        survey(trips, key: currentKey(languageTag)).exceedsBudget
    }

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
        let initial = survey(trips, key: currentKey(languageTag))
        // Small libraries build off-main too, so the first keystroke finds them cached.
        guard !initial.missing.isEmpty || initial.exceedsBudget else { return }
        let wipe = wipeRevision
        let entrySerial = buildSerial
        scheduleRebuild(key: currentKey(languageTag), from: trips)
        await awaitBuilds(wipe: wipe)
        // Only a build already in flight on entry ran, and it may have
        // fetched before rows saved since (a remote merge ahead of its
        // tracker bump, same key). One follow-up build can see them.
        if !Task.isCancelled, wipe == wipeRevision, buildTask == nil, buildSerial == entrySerial,
           survey(trips, key: currentKey(languageTag)).exceedsBudget {
            scheduleRebuild(key: currentKey(languageTag), from: trips)
            await awaitBuilds(wipe: wipe)
        }
        while !Task.isCancelled, wipe == wipeRevision {
            let key = currentKey(languageTag)
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
    /// `TripSearch.normalizedFormsCache`, and revokes any in-flight build
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
        TripSearch.normalizedFormsCache.withLock { $0.removeAll() }
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
            document: .make(from: trip, languageTag: key.languageTag, normalizer: normalizer),
            fingerprint: fingerprint,
            key: key,
            stamp: cacheRevision)
        #if DEBUG
        synchronousBuildCount += 1
        #endif
    }

    private func currentKey(_ languageTag: String) -> TripSearchIndexKey {
        TripSearchIndexKey(
            storeToken: tracker.token(for: [.trip, .stay]),
            languageTag: languageTag,
            timeZoneIdentifier: TimeZone.current.identifier)
    }

    // MARK: - Off-main rebuild

    /// One build in flight; a request for a different key while it runs
    /// queues exactly one follow-up.
    private func scheduleRebuild(key: TripSearchIndexKey, from trips: [Trip]) {
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
    /// fingerprint, keeping the index, memo and `generation`.
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
        if rerun, let container {
            startBuild(key: currentKey(key.languageTag), container: container)
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
