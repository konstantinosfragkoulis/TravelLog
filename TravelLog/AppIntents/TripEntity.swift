//
//  TripEntity.swift
//  TravelLog
//
//  App Intents surface for trips.
//  One entity definition powers Spotlight (via `IndexedEntity` +
//  `SpotlightIndexer`), the Shortcuts app, Siri App Shortcuts, and — once
//  built against the iOS 27 SDK — Siri AI's semantic entity resolution.
//

import AppIntents
import CoreSpotlight
import Foundation
import SwiftData
import UniformTypeIdentifiers

// MARK: - TripEntity

/// Sendable value-type mirror of a `Trip` for the App Intents machinery
/// (models never cross an isolation boundary; only value copies do).
///
/// **Identity caveat** (mirrors `PinnedTripsStorage`): `Trip.id` is stable
/// and syncs through CloudKit (the classifier reuses the ongoing trip's row
/// in place), but Settings → "Rebuild Trip History" re-mints every
/// non-user-edited trip, and merges or deletes retire ids.
/// Consumers must treat a UUID that no longer resolves as a soft miss
/// (`TripEntityQuery.entities(for:)` silently drops it; `SpotlightIndexer`
/// re-donates on every data epoch so stale index entries heal quickly).
///
/// `nonisolated`: pure value type read by the App Intents framework from
/// arbitrary executors — the project-wide pattern for value types shared
/// with nonisolated contexts.
nonisolated struct TripEntity: AppEntity, IndexedEntity {

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Trip")
    static let defaultQuery = TripEntityQuery()

    /// The trip's UUID and, for an entity that shows one physical row (a
    /// search result, the trip on screen), that row (`TripEntityID`).
    let id: TripEntityID

    /// `Trip.id`, the logical identity favorites and photo choices key on.
    var tripID: UUID { id.tripID }

    /// `Trip.displayName` at snapshot time (custom name > AI title >
    /// destination summary > "Trip").
    let title: String

    /// Every valid title for the current canonical source. This preserves
    /// search by a title the user saw before switching app languages.
    let titleAliases: [String]

    /// `Trip.destinationSummary` ("London, Oxford").
    let destinationSummary: String

    let startDate: Date
    let endDate: Date?

    /// True while the user hasn't returned home (`Trip.isComplete == false`).
    let isOngoing: Bool

    /// ISO 3166-1 alpha-2 codes of destination stays, visit order.
    let countryCodes: [String]

    /// English country names (en_US pin, mirroring `TripSearch`'s haystack
    /// locale so Spotlight keywords stay language-stable).
    let countryNames: [String]

    /// Destination-stay place names at display granularity
    /// (`metroName ?? islandName ?? locality`), deduplicated, visit order.
    let localities: [String]

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(dateRangeText)\(flags.isEmpty ? "" : " \(flags)")",
            image: .init(systemName: isOngoing ? "location.fill" : "airplane")
        )
    }

    /// Unique country flag emojis, visit order.
    var flags: String {
        countryCodes.compactMap { flagEmoji(for: $0) }.joined(separator: " ")
    }

    var dateRangeText: String {
        let tag = AppLanguagePreference.currentTag()
        return dateRangeText(locale: AppLanguagePreference.locale(for: tag))
    }

    /// Locale-explicit seam used by Spotlight donation. App Intents normally
    /// resolve in the app process, but the persisted Spotlight attribute must
    /// be rebuilt deterministically for the mirrored app language after a
    /// per-app language relaunch.
    func dateRangeText(locale: Locale) -> String {
        let languageTag = AppLanguagePreference.normalizedSupportedTag(
            FMLanguagePolicy.canonicalLanguageTag(for: locale)
        ) ?? "en"
        let style = Date.FormatStyle(
            date: .abbreviated,
            time: .omitted,
            locale: locale
        )
        let start = startDate.formatted(style)
        if isOngoing {
            return Self.localizedFormat(
                key: "app-intent.trip-entity.date-range.ongoing",
                defaultValue: "%@ · ongoing",
                languageTag: languageTag,
                locale: locale,
                arguments: [start]
            )
        }
        guard let endDate else { return start }
        return Self.localizedFormat(
            key: "app-intent.trip-entity.date-range.completed",
            defaultValue: "%1$@ to %2$@",
            languageTag: languageTag,
            locale: locale,
            arguments: [start, endDate.formatted(style)]
        )
    }

    /// The exact description persisted in CoreSpotlight. Keeping this as a
    /// pure locale-explicit value lets the donation digest cover the final
    /// localized bytes rather than only their raw date inputs.
    func spotlightContentDescription(locale: Locale) -> String {
        let dateRange = dateRangeText(locale: locale)
        return destinationSummary.isEmpty
            ? dateRange
            : "\(destinationSummary) · \(dateRange)"
    }

    /// Spotlight attributes. Keywords carry the place vocabulary a user
    /// would type ("Paris", "Greece", "GR"); dates enable Spotlight's
    /// date-range narrowing.
    var attributeSet: CSSearchableItemAttributeSet {
        let tag = AppLanguagePreference.currentTag()
        return attributeSet(locale: AppLanguagePreference.locale(for: tag))
    }

    func attributeSet(locale: Locale) -> CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: UTType.content)
        attributes.title = title
        attributes.alternateNames = TripSearch.searchVocabulary(titleAliases)
            .filter { $0 != title }
        attributes.contentDescription = spotlightContentDescription(locale: locale)
        attributes.keywords = spotlightKeywords(locale: locale)
        attributes.startDate = startDate
        attributes.endDate = endDate
        return attributes
    }

    /// Place vocabulary plus Gregorian year and month words for the start
    /// and end dates in English and the app language, so a trip stays
    /// findable by date words in either language.
    func spotlightKeywords(locale: Locale) -> [String] {
        let localizedCountries = countryCodes.compactMap {
            locale.localizedString(forRegionCode: $0)
        }
        let languageTag = AppLanguagePreference.normalizedSupportedTag(
            FMLanguagePolicy.canonicalLanguageTag(for: locale)
        ) ?? "en"
        var dateWords = TripSearchDocument.dateWords(
            start: startDate, end: endDate, languageTag: "en")
        if languageTag != "en" {
            dateWords += TripSearchDocument.dateWords(
                start: startDate, end: endDate, languageTag: languageTag)
        }
        return TripSearch.searchVocabulary(
            titleAliases + localities + countryNames
                + localizedCountries + countryCodes + dateWords)
    }

    private static func localizedFormat(
        key: String,
        defaultValue: String,
        languageTag: String,
        locale: Locale,
        arguments: [CVarArg]
    ) -> String {
        let format = AppLanguagePreference.localizedString(
            key: key,
            defaultValue: defaultValue,
            languageTag: languageTag)
        return String(format: format, locale: locale, arguments: arguments)
    }
}

// MARK: - TripEntityID

/// A `TripEntity`'s identity. `Trip.id` is not unique: two physical rows can
/// share it (converged imports) and differ in name, stays and dates. An
/// entity built from one row (a search result, the trip on screen) carries
/// that row, and resolves to exactly it or to nothing: when the row is gone,
/// no twin stands in for it. A UUID-only identity (Spotlight items, saved
/// Shortcuts, Favorites, Where Was I) resolves to its twins' representative
/// (`TripEntityFetcher.representative(of:)`), or to nothing when the twins
/// disagree.
///
/// The identifier string is the UUID, so UUID-only identities stay what
/// earlier builds donated and saved; a row adds "~" and the row's
/// `PersistentIdentifier` as base64url JSON.
nonisolated struct TripEntityID: Hashable, Sendable, EntityIdentifierConvertible {
    let tripID: UUID
    let row: PersistentIdentifier?

    init(tripID: UUID, row: PersistentIdentifier? = nil) {
        self.tripID = tripID
        self.row = row
    }

    private static let separator: Character = "~"

    var entityIdentifierString: String {
        guard let row, let token = Self.token(for: row) else { return tripID.uuidString }
        return "\(tripID.uuidString)\(Self.separator)\(token)"
    }

    /// nil for a string that is no UUID, or whose row part does not decode:
    /// a row identity never degrades to the UUID's representative.
    static func entityIdentifier(for entityIdentifierString: String) -> TripEntityID? {
        let parts = entityIdentifierString.split(separator: separator, maxSplits: 1)
        guard let first = parts.first, let tripID = UUID(uuidString: String(first)) else { return nil }
        guard parts.count == 2 else { return TripEntityID(tripID: tripID) }
        guard let row = row(fromToken: String(parts[1])) else { return nil }
        return TripEntityID(tripID: tripID, row: row)
    }

    static func token(for row: PersistentIdentifier) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(row) else { return nil }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func row(fromToken token: String) -> PersistentIdentifier? {
        var base64 = token
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONDecoder().decode(PersistentIdentifier.self, from: data)
    }
}

// MARK: - TripEntityQuery

/// Resolves `TripEntity` instances for the system. String resolution runs
/// the same resolver as the Siri search intent and the in-app search bar
/// (`TripIntentSearch.entityMatches`: place reading, dates, durations, typo
/// tolerance, whole-query matches only), off the main thread, so Siri,
/// Shortcuts and the Trips list agree on what matches.
nonisolated struct TripEntityQuery: EntityQuery, EnumerableEntityQuery, EntityStringQuery {

    private let container: ModelContainer?
    private let isPersistentStore: Bool?

    init() {
        container = nil
        isPersistentStore = nil
    }

    init(container: ModelContainer, isPersistentStore: Bool) {
        self.container = container
        self.isPersistentStore = isPersistentStore
    }

    private func persistentContainer() throws -> ModelContainer {
        // Open the container first: its initializer records the store mode.
        let container = container ?? AppDelegate.modelContainer
        try IntentDataError.requirePersistentStore(isPersistentStore ?? AppDelegate.containerMode.isPersistent)
        return container
    }

    func entities(for identifiers: [TripEntityID]) async throws -> [TripEntity] {
        let container = try persistentContainer()
        return try IntentDataError.reading("Trip entities") {
            try TripEntityFetcher.entities(for: identifiers, container: container)
        }
    }

    func allEntities() async throws -> [TripEntity] {
        let container = try persistentContainer()
        return try IntentDataError.reading("All trip entities") {
            try TripEntityFetcher.allEntities(container: container)
        }
    }

    func suggestedEntities() async throws -> [TripEntity] {
        let container = try persistentContainer()
        return try IntentDataError.reading("Suggested trip entities") {
            try TripEntityFetcher.recentEntities(limit: 6, container: container)
        }
    }

    /// Only whole-query matches resolve: a partial match is never returned
    /// as a match (`TripIntentSearch.entityMatches`). A deletion that clears
    /// the Stats snapshot while the search runs revokes its answer, as in
    /// `TripIntentSearch.run`.
    func entities(matching string: String) async throws -> [TripEntity] {
        let container = try persistentContainer()
        let clearGeneration = StatsSnapshotStore.clearGeneration
        do {
            let matches = try await TripIntentSearch.entityMatchesOffMain(query: string, container: container)
            try TripIntentSearch.refuseIfRevoked(since: clearGeneration)
            return matches
        } catch {
            throw IntentDataError.mapped(error, intent: "Trip entity search")
        }
    }
}

// MARK: - TripEntityFetcher

/// Off-main fetch + snapshot reduction for `TripEntity` — the
/// `StatsAggregator` pattern: a `nonisolated` enum whose synchronous
/// functions open their OWN `ModelContext(container)`, touch only stored
/// properties (macro accessors are nonisolated) plus the hand-marked
/// `nonisolated` derived members (`Trip.displayName`), and discard the
/// models on the same executor. Only Sendable `TripEntity` values escape.
///
/// Static functions take the container as a parameter so tests can drive
/// them against `TestSupport.makeInMemoryContainer()`.
nonisolated enum TripEntityFetcher {

    /// Every trip, newest first: one UUID-only entity per `Trip.id`, showing
    /// its twins' representative, and one entity per row of twins that
    /// disagree (`entities(forTwins:)`). Throws on a failed fetch so a read
    /// failure is never mistaken for an empty library.
    static func allEntities(container: ModelContainer) throws -> [TripEntity] {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<Trip>(
            sortBy: [SortDescriptor(\Trip.startDate, order: .reverse)]
        )
        // entity(from:) reads every trip's stays and, through the title aliases,
        // its title variants: one batched fetch each instead of one per trip.
        descriptor.relationshipKeyPathsForPrefetching = [\.stays, \.localizedTitles]
        try IntentRead.check(.tripEntities)
        return groupedByID(try context.fetch(descriptor)).flatMap { entities(forTwins: $0) }
    }

    /// UUID-only identities (`TripEntityID`) for `ids`, as `entities(for:)`
    /// resolves them.
    static func entities(for ids: [UUID], container: ModelContainer) throws -> [TripEntity] {
        try entities(for: ids.map { TripEntityID(tripID: $0) }, container: container)
    }

    /// Resolve specific identities, preserving the input order. A row
    /// identity resolves to that row only; a UUID-only one to its twins'
    /// representative. Unknown ones (churned ongoing-trip UUIDs, stale
    /// Spotlight entries, a row since deleted) and UUIDs whose twins
    /// disagree are dropped silently — the system treats a missing entity as
    /// "no longer exists". A failed fetch throws instead, so it never reads
    /// as every trip gone.
    static func entities(for identifiers: [TripEntityID], container: ModelContainer) throws -> [TripEntity] {
        guard !identifiers.isEmpty else { return [] }
        let wanted = Set(identifiers.map(\.tripID))
        let context = ModelContext(container)
        let predicate = #Predicate<Trip> { wanted.contains($0.id) }
        try IntentRead.check(.tripEntities)
        // `Trip.id` has no uniqueness constraint (CloudKit forbids
        // `@Attribute(.unique)`), so one id can hold several rows.
        let rowsByID = Dictionary(grouping: try context.fetch(FetchDescriptor<Trip>(predicate: predicate)), by: \.id)
        return identifiers.compactMap { identifier in
            guard let trip = resolve(identifier, among: rowsByID[identifier.tripID] ?? []) else { return nil }
            return entity(from: trip, id: identifier)
        }
    }

    /// The row `identifier` names among the rows sharing its UUID: its own
    /// row, never a twin, or for a UUID-only identity the representative.
    static func resolve(_ identifier: TripEntityID, among rows: [Trip]) -> Trip? {
        let live = rows.filter { !$0.isDeleted && $0.id == identifier.tripID }
        guard let row = identifier.row else { return representative(of: live) }
        let token = TripEntityID.token(for: row)
        return live.first { $0.persistentModelID == row || (token != nil && TripEntityID.token(for: $0.persistentModelID) == token) }
    }

    /// The row a UUID-only route opens among rows sharing one `Trip.id`:
    /// the only populated one (an empty twin is a shell), or, when several
    /// are populated (or none is), one of them only if they hold the same
    /// stays under the same name, picked by row identifier so every caller
    /// agrees. Twins that disagree have no representative: opening either
    /// could show a trip the route never meant.
    static func representative(of rows: [Trip]) -> Trip? {
        let live = rows.filter { !$0.isDeleted }
        let populated = live.filter { !($0.stays ?? []).isEmpty }
        let candidates = populated.isEmpty ? live : populated
        guard let first = candidates.first else { return nil }
        guard candidates.count > 1 else { return first }
        func signature(_ trip: Trip) -> (Set<UUID>, String, Date, Date?) {
            (Set((trip.stays ?? []).map(\.id)), trip.displayName(languageTag: "en"), trip.startDate, trip.endDate)
        }
        let reference = signature(first)
        guard candidates.dropFirst().allSatisfy({ signature($0) == reference }) else { return nil }
        return candidates.min { (TripEntityID.token(for: $0.persistentModelID) ?? "") < (TripEntityID.token(for: $1.persistentModelID) ?? "") }
    }

    /// The entities one `Trip.id` lists as: its representative under the
    /// UUID-only identity, or, when its twins disagree, each populated row
    /// (every row when none is) under its own row identity.
    static func entities(forTwins rows: [Trip]) -> [TripEntity] {
        guard let first = rows.first else { return [] }
        if let representative = representative(of: rows) {
            return [entity(from: representative, id: TripEntityID(tripID: first.id))]
        }
        let populated = rows.filter { !$0.isDeleted && !($0.stays ?? []).isEmpty }
        return (populated.isEmpty ? rows.filter { !$0.isDeleted } : populated).map {
            entity(from: $0, id: TripEntityID(tripID: $0.id, row: $0.persistentModelID))
        }
    }

    /// Rows grouped by `Trip.id`, in the order each id first appears.
    private static func groupedByID(_ trips: [Trip]) -> [[Trip]] {
        var indexByID: [UUID: Int] = [:]
        var groups: [[Trip]] = []
        for trip in trips {
            if let index = indexByID[trip.id] {
                groups[index].append(trip)
            } else {
                indexByID[trip.id] = groups.count
                groups.append([trip])
            }
        }
        return groups
    }

    /// The most recently started trips (ongoing first by virtue of the
    /// start-date sort) — feeds `suggestedEntities` for Shortcuts pickers.
    /// `limit` counts distinct `Trip.id`s, so twins never crowd out another
    /// trip: a page that held twins is followed by the next one. Each id
    /// lists as `entities(forTwins:)` lists it.
    static func recentEntities(limit: Int, container: ModelContainer) throws -> [TripEntity] {
        guard limit > 0 else { return [] }
        let context = ModelContext(container)
        // The id tiebreak keeps offset pages consistent across fetches.
        var descriptor = FetchDescriptor<Trip>(
            sortBy: [SortDescriptor(\Trip.startDate, order: .reverse), SortDescriptor(\Trip.id)]
        )
        descriptor.fetchLimit = limit
        try IntentRead.check(.tripEntities)
        var seen = Set<UUID>()
        var ids: [UUID] = []
        while ids.count < limit {
            let page = try context.fetch(descriptor)
            for trip in page where ids.count < limit && seen.insert(trip.id).inserted {
                ids.append(trip.id)
            }
            guard page.count == limit else { break }
            descriptor.fetchOffset = (descriptor.fetchOffset ?? 0) + page.count
        }
        let wanted = Set(ids)
        let rowsByID = Dictionary(
            grouping: try context.fetch(FetchDescriptor<Trip>(predicate: #Predicate<Trip> { wanted.contains($0.id) })),
            by: \.id)
        return ids.flatMap { entities(forTwins: rowsByID[$0] ?? []) }
    }

    /// Snapshot one trip under `id` (the trip's UUID-only identity when
    /// nil). Reads stored fields and `nonisolated` members only — safe from
    /// any executor.
    static func entity(
        from trip: Trip,
        id: TripEntityID? = nil,
        languageTag: String = AppLanguagePreference.currentTag()
    ) -> TripEntity {
        let codes = trip.countryCodes.split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let englishLocale = Locale(identifier: "en_US")
        let names = codes.compactMap { englishLocale.localizedString(forRegionCode: $0) }

        // Destination-stay place names at display granularity, visit order,
        // deduplicated — the `metroName ?? islandName ?? locality` chain
        // `Trip.recomputeSummary` uses. Stored-field access only
        // (`Trip.destinations` is a MainActor computed property; this
        // re-derives it from stored `categoryRaw`/`orderInTrip`).
        let destinationStays = (trip.stays ?? [])
            .filter { $0.categoryRaw == StayCategory.destination.rawValue }
            .sorted { ($0.orderInTrip ?? 0) < ($1.orderInTrip ?? 0) }
        var seen = Set<String>()
        var places: [String] = []
        for stay in destinationStays {
            guard let name = stay.placeGroupName,
                  !name.isEmpty, seen.insert(name).inserted else { continue }
            places.append(name)
        }

        return TripEntity(
            id: id ?? TripEntityID(tripID: trip.id),
            title: trip.displayName(languageTag: languageTag),
            titleAliases: TripSearch.titleAliases(
                for: trip,
                languageTag: languageTag),
            destinationSummary: trip.destinationSummary,
            startDate: trip.startDate,
            endDate: trip.endDate,
            isOngoing: !trip.isComplete,
            countryCodes: codes,
            countryNames: names,
            localities: places
        )
    }
}
