//
//  SearchTripsIntent.swift
//  TravelLog
//
//  Read-only App Intent over the shared local trip resolver (tiered typo
//  tolerant matching, corpus-aware month/season disambiguation, structured
//  filters), the same resolver `TripsListView` uses for the in-app search
//  bar.
//

import AppIntents
import Foundation
import SwiftData
import SwiftUI

// MainActor-isolated (target default): `@Parameter` is a mutable stored
// property, which `nonisolated` types forbid. perform() therefore starts
// on the MainActor; the heavy paths hop off explicitly.
struct SearchTripsIntent: AppIntent {

    static let title: LocalizedStringResource = "Search Trips"
    /// Travel history is personal, so a locked device must be unlocked first.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static let description = IntentDescription(
        "Finds trips in your travel journal by place, country, date, or name.",
        categoryName: "Trips"
    )

    @Parameter(title: "Search For", requestValueDialog: "What trip are you looking for?")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Find trips matching \(\.$query)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[TripEntity]> & ProvidesDialog & ShowsSnippetView {
        // The container initializer records the mode, so open it first. A
        // failed read or the in-memory fallback store is never "no trips
        // matched".
        let container = AppDelegate.modelContainer
        try IntentDataError.requirePersistentStore(AppDelegate.containerMode.isPersistent)
        let outcome: TripIntentSearch.Outcome
        do {
            outcome = try await TripIntentSearch.run(query: query, container: container)
        } catch {
            throw IntentDataError.mapped(error, intent: "Search Trips")
        }

        // Suggestions are shown and named as such, never returned as
        // results: a chained Shortcut gets only trips that match it all.
        let message = Self.message(for: outcome, query: query)
        return .result(
            value: outcome.matches,
            dialog: IntentDialog("\(message)"),
            view: TripListSnippetView(trips: outcome.matches.isEmpty ? outcome.suggestions : outcome.matches)
        )
    }

    /// What Siri says: the trips that match the whole query, or, when none
    /// does, that none did and which trips came closest.
    static func message(for outcome: TripIntentSearch.Outcome, query: String) -> String {
        let matches = outcome.matches
        switch matches.count {
        case 0:
            guard !outcome.suggestions.isEmpty else {
                return String(
                    localized: "app-intent.search-trips.result.none",
                    defaultValue: "No trips matched “\(query)”.",
                    comment: "Siri response when a trip search has no results."
                )
            }
            let names = outcome.suggestions.prefix(3).map(\.title).joined(separator: ", ")
            return String(
                localized: "app-intent.search-trips.result.partial",
                defaultValue: "No trip matched all of “\(query)”. Closest: \(names).",
                comment: "Siri response when no trip matches the whole search but some match part of it (a place, not the year). The first placeholder is the search, the second up to three trip names."
            )
        case 1:
            return String(
                localized: "app-intent.search-trips.result.one",
                defaultValue: "Found one trip: \(matches[0].title).",
                comment: "Siri response when a trip search has one result."
            )
        default:
            let names = matches.prefix(3).map(\.title).joined(separator: ", ")
            if matches.count > 3 {
                return String(
                    localized: "app-intent.search-trips.result-with-more",
                    defaultValue: "Found \(matches.count, format: .number.grouping(.never)) trips: \(names), and more.",
                    comment: "Siri response for multiple trip results when additional results are omitted."
                )
            }
            return String(
                localized: "app-intent.search-trips.result.other",
                defaultValue: "Found \(matches.count, format: .number.grouping(.never)) trips: \(names).",
                comment: "Siri response when a trip search has multiple results."
            )
        }
    }
}

// MARK: - TripIntentSearch

/// The search orchestration, split out of `perform()` so tests can drive
/// it against a throwaway container (the intent itself is welded to
/// `AppDelegate.modelContainer`).
nonisolated enum TripIntentSearch {

    /// The shared resolver over documents built off-main in this call's own
    /// `ModelContext` (`TripSearchDocument.make(from:)` reads stored and
    /// `nonisolated` members only). Siri queries are complete sentences, so
    /// the last word is never a trailing partial. Siri has no sort: strong,
    /// then similar, then partial, newest first within each; duplicate
    /// `Trip.id` rows (CloudKit twins) collapse to the first. An empty or
    /// whitespace query returns []. A failed trip or Home read throws.
    static func localMatches(
        query: String,
        container: ModelContainer,
        languageTag: String = AppLanguagePreference.currentTag()
    ) throws -> [TripEntity] {
        try rankedLocalMatches(query: query, container: container, languageTag: languageTag).map(\.entity)
    }

    /// `localMatches` on the concurrent executor, so a background Siri or
    /// Shortcuts request never faults every stay on the main thread.
    @concurrent
    static func localMatchesOffMain(query: String, container: ModelContainer) async throws -> [TripEntity] {
        try localMatches(query: query, container: container)
    }

    /// The machine-readable answer (`EntityStringQuery`): only results that
    /// satisfy the whole query, so a partial match (a place whose year or
    /// duration differs from the query's) never resolves a parameter.
    static func entityMatches(
        query: String,
        container: ModelContainer,
        languageTag: String = AppLanguagePreference.currentTag()
    ) throws -> [TripEntity] {
        try rankedLocalMatches(query: query, container: container, languageTag: languageTag)
            .filter { $0.strength != .partial }
            .map(\.entity)
    }

    @concurrent
    static func entityMatchesOffMain(query: String, container: ModelContainer) async throws -> [TripEntity] {
        try entityMatches(query: query, container: container)
    }

    struct RankedMatch: Sendable {
        let entity: TripEntity
        let strength: TripSearchStrength
    }

    static func rankedLocalMatches(
        query: String,
        container: ModelContainer,
        languageTag: String = AppLanguagePreference.currentTag()
    ) throws -> [RankedMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<Trip>(
            sortBy: [SortDescriptor(\Trip.startDate, order: .reverse)]
        )
        descriptor.relationshipKeyPathsForPrefetching = [\.stays, \.localizedTitles]
        try IntentRead.check(.searchTrips)
        let trips = try context.fetch(descriptor).filter { !$0.isDeleted }
        guard !trips.isEmpty else { return [] }
        let normalizer = TripSearchNormalizer()
        let homes = try TripSearchHome.fetchAll(in: context)
        // Off-main (the Siri paths): island sizes for the island facet, regions for region names.
        if !Thread.isMainThread {
            IslandAreaTable.shared.prepare()
            StayAreaTable.shared.prepare()
        }
        let index = TripSearchIndex(documents: trips.map {
            TripSearchDocument.make(from: $0, languageTag: languageTag, normalizer: normalizer, homes: homes)
        })
        let matches = TripQueryParser.searchTrips(
            index: index,
            query: trimmed,
            allowsTrailingPartial: false,
            languageTag: languageTag
        )
        // Stable: index (newest first) order within each strength.
        let ordered = matches.enumerated()
            .sorted { ($0.element.strength, $0.offset) < ($1.element.strength, $1.offset) }
            .map(\.element)
        // Collapse duplicate ids (CloudKit-synced duplicate rows) to the best
        // ranked one. Each result names the row it matched, so opening it
        // opens that row, never a twin with another name or stays.
        var seen = Set<UUID>()
        return ordered.compactMap { match in
            let trip = trips[match.documentIndex]
            guard seen.insert(trip.id).inserted else { return nil }
            return RankedMatch(
                entity: TripEntityFetcher.entity(
                    from: trip, id: TripEntityID(tripID: trip.id, row: trip.persistentModelID),
                    languageTag: languageTag),
                strength: match.strength
            )
        }
    }

    /// A search's answer. `matches` satisfy the whole query (strong or
    /// similar local matches); `suggestions` match only part of it (a
    /// partial match drops a year or duration the query asked for), so they
    /// are never presented or returned as matches.
    struct Outcome: Sendable {
        var matches: [TripEntity] = []
        var suggestions: [TripEntity] = []
    }

    /// The answer from the local results: strong and similar matches, with
    /// partial ones as suggestions.
    static func outcome(local: [RankedMatch]) -> Outcome {
        let full = local.filter { $0.strength != .partial }.map(\.entity)
        let partial = local.filter { $0.strength == .partial }.map(\.entity)
        return Outcome(matches: full, suggestions: partial)
    }

    /// Full search: the shared local resolver off the main actor, with
    /// partial results as suggestions, as `TripsListView` labels them too.
    /// A failed store read throws rather than reading as no matches. A
    /// deletion that clears the Stats snapshot (Delete All Data among them)
    /// while the search runs revokes its answer: the search throws rather
    /// than speak deleted trips.
    static func run(query: String, container: ModelContainer) async throws -> Outcome {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Outcome() }

        let clearGeneration = StatsSnapshotStore.clearGeneration
        let local = try await rankedLocalMatchesOffMain(query: trimmed, container: container)
        try refuseIfRevoked(since: clearGeneration)
        return outcome(local: local)
    }

    /// Throws when the caller was cancelled, or when a deletion that clears
    /// the Stats snapshot moved its generation past `clearGeneration`,
    /// captured before the search read any trip.
    static func refuseIfRevoked(since clearGeneration: Int) throws {
        try Task.checkCancellation()
        guard clearGeneration == StatsSnapshotStore.clearGeneration else { throw IntentDataError.unavailable }
    }

    @concurrent
    private static func rankedLocalMatchesOffMain(
        query: String,
        container: ModelContainer
    ) async throws -> [RankedMatch] {
        try rankedLocalMatches(query: query, container: container)
    }
}
