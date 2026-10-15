//
//  TravelStatsIntent.swift
//  TravelLog
//
//  Read-only App Intent over `StatsAggregator`: lifetime totals via
//  `StatsAggregator.passportSummary`, or a year-scoped summary via
//  `StatsAggregator.yearSummary` when the user names a year.
//

import AppIntents
import Foundation
import SwiftData
import SwiftUI

// MainActor-isolated (target default): `@Parameter` is a mutable stored
// property, which `nonisolated` types forbid. The aggregation passes are
// dispatched to a detached task so a Siri query never runs a full-table
// reduction on the main thread (the StatsView pattern).
struct TravelStatsIntent: AppIntent {

    static let title: LocalizedStringResource = "Travel Stats"
    /// Travel history is personal, so a locked device must be unlocked first.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static let description = IntentDescription(
        LocalizedStringResource(
            "app-intent.travel-stats.description",
            defaultValue: "Summarizes your travel (countries, trips, days away, and flights) for your lifetime or a single year.",
            comment: "Siri travel statistics description; days away includes domestic trips."),
        categoryName: "Stats"
    )

    @Parameter(title: "Year", description: "A specific year, like 2025. Leave empty for lifetime stats.")
    var year: Int?

    static var parameterSummary: some ParameterSummary {
        Summary("Get travel stats for \(\.$year)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        // The container initializer records the mode, so open it first.
        let container = AppDelegate.modelContainer
        let isPersistentStore = AppDelegate.containerMode.isPersistent
        // A deletion that clears the Stats snapshot while the summary runs
        // revokes its answer, as in `TripIntentSearch.run`.
        let clearGeneration = StatsSnapshotStore.clearGeneration

        let heading: String
        let stats: [SnippetStat]
        let dialog: IntentDialog

        if let year {
            // A failed read throws IntentDataError; only a complete summary
            // reaches the dialog, so "No travel recorded" means exactly that.
            let summary = try await TravelStatsSummaryLoader.yearSummary(
                year, container: container, isPersistentStore: isPersistentStore)
            // `String(year)` everywhere — LocalizedStringResource interpolation
            // would format 2025 as "2,025".
            heading = String(year)
            stats = snippetStats(
                countries: summary.countries.count,
                trips: summary.trips,
                daysAbroad: summary.daysAbroad,
                flights: summary.flights
            )
            if summary.trips > 0 || !summary.countries.isEmpty || summary.flights > 0 || summary.daysAbroad > 0 {
                let countryCount = summary.countries.count
                let text: String
                switch (summary.trips == 1, countryCount == 1, summary.flights == 1) {
                case (true, true, true):
                    text = String(
                        localized: "app-intent.travel-stats.year.trip-one.country-one.flight.one",
                        defaultValue: "In \(year, format: .number.grouping(.never)): \(summary.trips, format: .number.grouping(.never)) trip to \(countryCount, format: .number.grouping(.never)) country, \(summary.daysAbroad, format: .number.grouping(.never)) days away, and \(summary.flights, format: .number.grouping(.never)) flight.",
                        comment: "Siri year travel summary with one trip, one country, and one flight."
                    )
                case (true, true, false):
                    text = String(
                        localized: "app-intent.travel-stats.year.trip-one.country-one.flight.other",
                        defaultValue: "In \(year, format: .number.grouping(.never)): \(summary.trips, format: .number.grouping(.never)) trip to \(countryCount, format: .number.grouping(.never)) country, \(summary.daysAbroad, format: .number.grouping(.never)) days away, and \(summary.flights, format: .number.grouping(.never)) flights.",
                        comment: "Siri year travel summary with one trip, one country, and multiple flights."
                    )
                case (true, false, true):
                    text = String(
                        localized: "app-intent.travel-stats.year.trip-one.country-other.flight.one",
                        defaultValue: "In \(year, format: .number.grouping(.never)): \(summary.trips, format: .number.grouping(.never)) trip to \(countryCount, format: .number.grouping(.never)) countries, \(summary.daysAbroad, format: .number.grouping(.never)) days away, and \(summary.flights, format: .number.grouping(.never)) flight.",
                        comment: "Siri year travel summary with one trip, multiple countries, and one flight."
                    )
                case (true, false, false):
                    text = String(
                        localized: "app-intent.travel-stats.year.trip-one.country-other.flight.other",
                        defaultValue: "In \(year, format: .number.grouping(.never)): \(summary.trips, format: .number.grouping(.never)) trip to \(countryCount, format: .number.grouping(.never)) countries, \(summary.daysAbroad, format: .number.grouping(.never)) days away, and \(summary.flights, format: .number.grouping(.never)) flights.",
                        comment: "Siri year travel summary with one trip, multiple countries, and multiple flights."
                    )
                case (false, true, true):
                    text = String(
                        localized: "app-intent.travel-stats.year.trip-other.country-one.flight.one",
                        defaultValue: "In \(year, format: .number.grouping(.never)): \(summary.trips, format: .number.grouping(.never)) trips to \(countryCount, format: .number.grouping(.never)) country, \(summary.daysAbroad, format: .number.grouping(.never)) days away, and \(summary.flights, format: .number.grouping(.never)) flight.",
                        comment: "Siri year travel summary with multiple trips, one country, and one flight."
                    )
                case (false, true, false):
                    text = String(
                        localized: "app-intent.travel-stats.year.trip-other.country-one.flight.other",
                        defaultValue: "In \(year, format: .number.grouping(.never)): \(summary.trips, format: .number.grouping(.never)) trips to \(countryCount, format: .number.grouping(.never)) country, \(summary.daysAbroad, format: .number.grouping(.never)) days away, and \(summary.flights, format: .number.grouping(.never)) flights.",
                        comment: "Siri year travel summary with multiple trips, one country, and multiple flights."
                    )
                case (false, false, true):
                    text = String(
                        localized: "app-intent.travel-stats.year.trip-other.country-other.flight.one",
                        defaultValue: "In \(year, format: .number.grouping(.never)): \(summary.trips, format: .number.grouping(.never)) trips to \(countryCount, format: .number.grouping(.never)) countries, \(summary.daysAbroad, format: .number.grouping(.never)) days away, and \(summary.flights, format: .number.grouping(.never)) flight.",
                        comment: "Siri year travel summary with multiple trips, multiple countries, and one flight."
                    )
                case (false, false, false):
                    text = String(
                        localized: "app-intent.travel-stats.year.trip-other.country-other.flight.other",
                        defaultValue: "In \(year, format: .number.grouping(.never)): \(summary.trips, format: .number.grouping(.never)) trips to \(countryCount, format: .number.grouping(.never)) countries, \(summary.daysAbroad, format: .number.grouping(.never)) days away, and \(summary.flights, format: .number.grouping(.never)) flights.",
                        comment: "Siri year travel summary with multiple trips, multiple countries, and multiple flights."
                    )
                }
                dialog = IntentDialog("\(text)")
            } else {
                let message = String(
                    localized: "app-intent.travel-stats.year.empty",
                    defaultValue: "No travel recorded in \(year, format: .number.grouping(.never)).",
                    comment: "Siri response when a year has no recorded travel."
                )
                dialog = IntentDialog("\(message)")
            }
        } else {
            // Focused fetch: the full `compute` derives HexVisibility,
            // Collections, On This Day and country stats, and only four
            // counters are read here. `passportSummary` reuses the
            // canonical `uniqueCountries` / completed-trip semantics —
            // parity is pinned by `passportSummaryMatchesFullCompute`.
            let summary = try await TravelStatsSummaryLoader.passportSummary(
                container: container, isPersistentStore: isPersistentStore)
            // `countries` is tracked-only; the caller owes the remembered
            // union, as `StatsView.passportDataForDisplay` does. `codes` is
            // loaded on init and refreshed on every KVS change
            // notification, so reading it is enough; it is MainActor-isolated.
            let remembered = await MainActor.run { RememberedCountriesStorage.shared.codes }
            let countries = summary.countries.union(remembered).count
            heading = String(
                localized: "app-intent.travel-stats.lifetime.heading",
                defaultValue: "All time",
                comment: "Heading for lifetime travel statistics in a Siri snippet."
            )
            stats = snippetStats(
                countries: countries,
                trips: summary.trips,
                daysAbroad: summary.daysAbroad,
                flights: summary.flights
            )
            if summary.trips > 0 || countries > 0 || summary.daysAbroad > 0 {
                let text: String
                switch (countries == 1, summary.trips == 1, summary.flights == 1) {
                case (true, true, true):
                    text = String(
                        localized: "app-intent.travel-stats.lifetime.country-one.trip-one.flight.one",
                        defaultValue: "You've visited \(countries, format: .number.grouping(.never)) country across \(summary.trips, format: .number.grouping(.never)) trip, with \(summary.daysAbroad, format: .number.grouping(.never)) days away and \(summary.flights, format: .number.grouping(.never)) flight.",
                        comment: "Lifetime Siri travel summary with one country, one trip, and one flight."
                    )
                case (true, true, false):
                    text = String(
                        localized: "app-intent.travel-stats.lifetime.country-one.trip-one.flight.other",
                        defaultValue: "You've visited \(countries, format: .number.grouping(.never)) country across \(summary.trips, format: .number.grouping(.never)) trip, with \(summary.daysAbroad, format: .number.grouping(.never)) days away and \(summary.flights, format: .number.grouping(.never)) flights.",
                        comment: "Lifetime Siri travel summary with one country, one trip, and multiple flights."
                    )
                case (true, false, true):
                    text = String(
                        localized: "app-intent.travel-stats.lifetime.country-one.trip-other.flight.one",
                        defaultValue: "You've visited \(countries, format: .number.grouping(.never)) country across \(summary.trips, format: .number.grouping(.never)) trips, with \(summary.daysAbroad, format: .number.grouping(.never)) days away and \(summary.flights, format: .number.grouping(.never)) flight.",
                        comment: "Lifetime Siri travel summary with one country, multiple trips, and one flight."
                    )
                case (true, false, false):
                    text = String(
                        localized: "app-intent.travel-stats.lifetime.country-one.trip-other.flight.other",
                        defaultValue: "You've visited \(countries, format: .number.grouping(.never)) country across \(summary.trips, format: .number.grouping(.never)) trips, with \(summary.daysAbroad, format: .number.grouping(.never)) days away and \(summary.flights, format: .number.grouping(.never)) flights.",
                        comment: "Lifetime Siri travel summary with one country, multiple trips, and multiple flights."
                    )
                case (false, true, true):
                    text = String(
                        localized: "app-intent.travel-stats.lifetime.country-other.trip-one.flight.one",
                        defaultValue: "You've visited \(countries, format: .number.grouping(.never)) countries across \(summary.trips, format: .number.grouping(.never)) trip, with \(summary.daysAbroad, format: .number.grouping(.never)) days away and \(summary.flights, format: .number.grouping(.never)) flight.",
                        comment: "Lifetime Siri travel summary with multiple countries, one trip, and one flight."
                    )
                case (false, true, false):
                    text = String(
                        localized: "app-intent.travel-stats.lifetime.country-other.trip-one.flight.other",
                        defaultValue: "You've visited \(countries, format: .number.grouping(.never)) countries across \(summary.trips, format: .number.grouping(.never)) trip, with \(summary.daysAbroad, format: .number.grouping(.never)) days away and \(summary.flights, format: .number.grouping(.never)) flights.",
                        comment: "Lifetime Siri travel summary with multiple countries, one trip, and multiple flights."
                    )
                case (false, false, true):
                    text = String(
                        localized: "app-intent.travel-stats.lifetime.country-other.trip-other.flight.one",
                        defaultValue: "You've visited \(countries, format: .number.grouping(.never)) countries across \(summary.trips, format: .number.grouping(.never)) trips, with \(summary.daysAbroad, format: .number.grouping(.never)) days away and \(summary.flights, format: .number.grouping(.never)) flight.",
                        comment: "Lifetime Siri travel summary with multiple countries, multiple trips, and one flight."
                    )
                case (false, false, false):
                    text = String(
                        localized: "app-intent.travel-stats.lifetime.country-other.trip-other.flight.other",
                        defaultValue: "You've visited \(countries, format: .number.grouping(.never)) countries across \(summary.trips, format: .number.grouping(.never)) trips, with \(summary.daysAbroad, format: .number.grouping(.never)) days away and \(summary.flights, format: .number.grouping(.never)) flights.",
                        comment: "Lifetime Siri travel summary with multiple countries, multiple trips, and multiple flights."
                    )
                }
                dialog = IntentDialog("\(text)")
            } else {
                let message = String(
                    localized: "app-intent.travel-stats.lifetime.empty",
                    defaultValue: "No trips recorded yet. Travel Log fills in as you travel.",
                    comment: "Siri response when no lifetime trips are recorded."
                )
                dialog = IntentDialog("\(message)")
            }
        }

        guard clearGeneration == StatsSnapshotStore.clearGeneration else { throw IntentDataError.unavailable }
        return .result(
            dialog: dialog,
            view: TravelStatsSnippetView(heading: heading, stats: stats)
        )
    }

    private func snippetStats(countries: Int, trips: Int, daysAbroad: Int, flights: Int) -> [SnippetStat] {
        [
            SnippetStat(
                label: countries == 1
                    ? String(localized: "app-intent.travel-stats.country-label.one", defaultValue: "Country", comment: "Singular country label in a Siri statistics snippet.")
                    : String(localized: "app-intent.travel-stats.country-label.other", defaultValue: "Countries", comment: "Plural country label in a Siri statistics snippet."),
                value: String(countries)
            ),
            SnippetStat(
                label: trips == 1
                    ? String(localized: "app-intent.travel-stats.trip-label.one", defaultValue: "Trip", comment: "Singular trip label in a Siri statistics snippet.")
                    : String(localized: "app-intent.travel-stats.trip-label.other", defaultValue: "Trips", comment: "Plural trip label in a Siri statistics snippet."),
                value: String(trips)
            ),
            SnippetStat(
                label: String(localized: "app-intent.travel-stats.days-abroad-label", defaultValue: "Days away", comment: "Days-away label in a Siri statistics snippet."),
                value: String(daysAbroad)
            ),
            SnippetStat(
                label: flights == 1
                    ? String(localized: "app-intent.travel-stats.flight-label.one", defaultValue: "Flight", comment: "Singular flight label in a Siri statistics snippet.")
                    : String(localized: "app-intent.travel-stats.flight-label.other", defaultValue: "Flights", comment: "Plural flight label in a Siri statistics snippet."),
                value: String(flights)
            ),
        ]
    }
}

// MARK: - TravelStatsSummaryLoader

/// Runs the focused summaries on a detached worker so a Siri query never
/// reduces full tables on the main thread. Caller cancellation reaches the
/// worker's reads and day walk. A failed read, or the in-memory fallback
/// store, throws `IntentDataError.unavailable`: an empty summary always means
/// an empty journal.
nonisolated enum TravelStatsSummaryLoader {

    static func yearSummary(
        _ year: Int, container: ModelContainer, isPersistentStore: Bool
    ) async throws -> StatsAggregator.YearSummary {
        try await detached(isPersistentStore: isPersistentStore) { checkCancellation in
            try StatsAggregator.yearSummary(
                container: container, year: year, checkCancellation: checkCancellation)
        }
    }

    static func passportSummary(
        container: ModelContainer, isPersistentStore: Bool
    ) async throws -> StatsAggregator.PassportSummary {
        try await detached(isPersistentStore: isPersistentStore) { checkCancellation in
            try StatsAggregator.passportSummary(
                container: container, checkCancellation: checkCancellation)
        }
    }

    /// The aggregator's DEBUG read hook rides into the detached worker with
    /// the caller's value, like `StatsAggregator.load`.
    private static func detached<Value: Sendable>(
        isPersistentStore: Bool,
        _ read: @escaping @Sendable (_ checkCancellation: () throws -> Void) throws -> Value
    ) async throws -> Value {
        #if DEBUG
        let readFailure = StatsAggregator.readFailureForTesting
        return try await IntentDataError.detachedRead(
            "Travel Stats", isPersistentStore: isPersistentStore
        ) { checkCancellation in
            try StatsAggregator.$readFailureForTesting.withValue(readFailure) {
                try read(checkCancellation)
            }
        }
        #else
        return try await IntentDataError.detachedRead(
            "Travel Stats", isPersistentStore: isPersistentStore, read)
        #endif
    }
}
