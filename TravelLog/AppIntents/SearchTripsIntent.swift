//
//  SearchTripsIntent.swift
//  TravelLog
//
//  Read-only App Intent over the shared local trip resolver (tiered typo
//  tolerant matching, corpus-aware month/season disambiguation, structured
//  filters), with Foundation Models fallback only when nothing matches
//  strongly or similarly, the same contract `TripsListView` implements for
//  the in-app search bar.
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
        let matches: [TripEntity]
        do {
            matches = try await TripIntentSearch.run(query: query, container: container)
        } catch {
            throw IntentDataError.mapped(error, intent: "Search Trips")
        }

        let dialog: IntentDialog
        switch matches.count {
        case 0:
            let message = String(
                localized: "app-intent.search-trips.result.none",
                defaultValue: "No trips matched “\(query)”.",
                comment: "Siri response when a trip search has no results."
            )
            dialog = IntentDialog("\(message)")
        case 1:
            let message = String(
                localized: "app-intent.search-trips.result.one",
                defaultValue: "Found one trip: \(matches[0].title).",
                comment: "Siri response when a trip search has one result."
            )
            dialog = IntentDialog("\(message)")
        default:
            let names = matches.prefix(3).map(\.title).joined(separator: ", ")
            if matches.count > 3 {
                let message = String(
                    localized: "app-intent.search-trips.result-with-more",
                    defaultValue: "Found \(matches.count, format: .number.grouping(.never)) trips: \(names), and more.",
                    comment: "Siri response for multiple trip results when additional results are omitted."
                )
                dialog = IntentDialog("\(message)")
            } else {
                let message = String(
                    localized: "app-intent.search-trips.result.other",
                    defaultValue: "Found \(matches.count, format: .number.grouping(.never)) trips: \(names).",
                    comment: "Siri response when a trip search has multiple results."
                )
                dialog = IntentDialog("\(message)")
            }
        }
        return .result(
            value: matches,
            dialog: dialog,
            view: TripListSnippetView(trips: matches)
        )
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
    /// whitespace query returns []. A failed trip read throws.
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
        let index = TripSearchIndex(documents: trips.map {
            TripSearchDocument.make(from: $0, languageTag: languageTag, normalizer: normalizer)
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
        // Collapse duplicate ids (CloudKit-synced duplicate rows) before the
        // snippet's `ForEach(id: \.id)` sees them — mirrors the
        // `uniquingKeysWith` guard in `TripEntityFetcher.entities(for:)`.
        var seen = Set<UUID>()
        return ordered.compactMap { match in
            let trip = trips[match.documentIndex]
            guard seen.insert(trip.id).inserted else { return nil }
            return RankedMatch(
                entity: TripEntityFetcher.entity(from: trip, languageTag: languageTag),
                strength: match.strength
            )
        }
    }

    /// Full search chain: the shared local resolver, then the FM fallback
    /// only when nothing matched strongly or similarly (partial results do
    /// not block it). FM trips win when it returns any; otherwise the
    /// partial results stand. Mirrors `TripsListView` semantics; the FM path
    /// degrades to the partial results when Apple Intelligence is
    /// unavailable or declines. A failed store read throws rather than
    /// reading as no matches. A deletion that clears the Stats snapshot
    /// (Delete All Data among them) while the search runs revokes its
    /// answer: the search throws rather than speak deleted trips.
    static func run(query: String, container: ModelContainer) async throws -> [TripEntity] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let clearGeneration = StatsSnapshotStore.clearGeneration
        let matches = try await search(trimmed, container: container)
        try Task.checkCancellation()
        guard clearGeneration == StatsSnapshotStore.clearGeneration else { throw IntentDataError.unavailable }
        return matches
    }

    private static func search(_ trimmed: String, container: ModelContainer) async throws -> [TripEntity] {
        let local = try await rankedLocalMatchesOffMain(query: trimmed, container: container)
        if local.contains(where: { $0.strength != .partial }) { return local.map(\.entity) }
        let partial = local.map(\.entity)
        guard FMLanguagePolicy.searchFMAllowed(
            supportsLocale: { _ in FMCapability.supportsCurrentLocale() }
        ) else { return partial }

        let snapshots = try await fallbackSnapshots(container: container)
        guard !snapshots.isEmpty else { return partial }
        switch await TripSearchAI.search(query: trimmed, snapshots: snapshots) {
        case .success(let ids):
            let found = try TripEntityFetcher.entities(for: ids, container: container)
            return found.isEmpty ? partial : found
        case .empty, .unavailable, .failed:
            return partial
        }
    }

    @concurrent
    private static func rankedLocalMatchesOffMain(
        query: String,
        container: ModelContainer
    ) async throws -> [RankedMatch] {
        try rankedLocalMatches(query: query, container: container)
    }

    /// Sendable snapshots for the FM tool, built only when FM runs. Models
    /// stay inside this MainActor hop (`TripSnapshot.init(from:)` reads
    /// MainActor members); snapshots come out.
    @MainActor
    private static func fallbackSnapshots(container: ModelContainer) throws -> [TripSnapshot] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Trip>(
            sortBy: [SortDescriptor(\Trip.startDate, order: .reverse)]
        )
        try IntentRead.check(.searchFallbackTrips)
        return try context.fetch(descriptor).map(TripSnapshot.init(from:))
    }
}
