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

/// Sendable value-type mirror of a `Trip` for the App Intents machinery —
/// the same snapshot discipline as `TripSnapshot` (models never cross an
/// isolation boundary; only value copies do).
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

    let id: UUID

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
                defaultValue: "%@ – ongoing",
                languageTag: languageTag,
                locale: locale,
                arguments: [start]
            )
        }
        guard let endDate else { return start }
        return Self.localizedFormat(
            key: "app-intent.trip-entity.date-range.completed",
            defaultValue: "%1$@ – %2$@",
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

// MARK: - TripEntityQuery

/// Resolves `TripEntity` instances for the system. String resolution runs
/// the same resolver as the Siri search intent and the in-app search bar
/// (`TripIntentSearch.localMatches`: place reading, dates, durations, typo
/// tolerance), off the main thread, so Siri, Shortcuts and the Trips list
/// agree on what matches.
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

    func entities(for identifiers: [UUID]) async throws -> [TripEntity] {
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

    /// A deletion that clears the Stats snapshot while the search runs
    /// revokes its answer, as in `TripIntentSearch.run`.
    func entities(matching string: String) async throws -> [TripEntity] {
        let container = try persistentContainer()
        let clearGeneration = StatsSnapshotStore.clearGeneration
        do {
            let matches = try await TripIntentSearch.localMatchesOffMain(query: string, container: container)
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

    /// Every trip, newest first, one entity per `Trip.id` (the first row of
    /// a twin set, as in `entities(for:)`). Throws on a failed fetch so a
    /// read failure is never mistaken for an empty library.
    static func allEntities(container: ModelContainer) throws -> [TripEntity] {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<Trip>(
            sortBy: [SortDescriptor(\Trip.startDate, order: .reverse)]
        )
        // entity(from:) reads every trip's stays and, through the title aliases,
        // its title variants: one batched fetch each instead of one per trip.
        descriptor.relationshipKeyPathsForPrefetching = [\.stays, \.localizedTitles]
        try IntentRead.check(.tripEntities)
        var seen = Set<UUID>()
        return try context.fetch(descriptor)
            .filter { seen.insert($0.id).inserted }
            .map { entity(from: $0) }
    }

    /// Resolve specific IDs, preserving the input order. Unknown IDs
    /// (churned ongoing-trip UUIDs, stale Spotlight entries) are dropped
    /// silently — the system treats a missing entity as "no longer exists".
    /// A failed fetch throws instead, so it never reads as every trip gone.
    static func entities(for identifiers: [UUID], container: ModelContainer) throws -> [TripEntity] {
        guard !identifiers.isEmpty else { return [] }
        let wanted = Set(identifiers)
        let context = ModelContext(container)
        let predicate = #Predicate<Trip> { wanted.contains($0.id) }
        try IntentRead.check(.tripEntities)
        let trips = try context.fetch(FetchDescriptor<Trip>(predicate: predicate))
        // `uniquingKeysWith`, NOT `uniqueKeysWithValues`:
        // `Trip.id` has no uniqueness constraint (CloudKit forbids
        // `@Attribute(.unique)`) and no deduplicator, so two rows sharing an
        // id — two-device JSON imports of the same export converging via
        // sync — would trap the intent/Spotlight process here.
        let byID = Dictionary(trips.map { ($0.id, entity(from: $0)) }, uniquingKeysWith: { first, _ in first })
        return identifiers.compactMap { byID[$0] }
    }

    /// The most recently started trips (ongoing first by virtue of the
    /// start-date sort) — feeds `suggestedEntities` for Shortcuts pickers.
    /// `limit` counts distinct `Trip.id`s, so twins never crowd out another
    /// trip: a page that held twins is followed by the next one.
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
        var trips: [Trip] = []
        while trips.count < limit {
            let page = try context.fetch(descriptor)
            for trip in page where trips.count < limit && seen.insert(trip.id).inserted {
                trips.append(trip)
            }
            guard page.count == limit else { break }
            descriptor.fetchOffset = (descriptor.fetchOffset ?? 0) + page.count
        }
        return trips.map { entity(from: $0) }
    }

    /// Snapshot one trip. Reads stored fields and `nonisolated` members
    /// only — safe from any executor, same contract as `TripSnapshot`.
    static func entity(
        from trip: Trip,
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
            id: trip.id,
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
