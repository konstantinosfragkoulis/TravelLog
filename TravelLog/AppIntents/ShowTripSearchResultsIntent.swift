//
//  ShowTripSearchResultsIntent.swift
//  TravelLog
//
//  `.system.search` adoption: the
//  generic "search in this app" hook the system gets regardless of which
//  other schemas an app adopts — and the integration iOS 27 renames
//  `.system.searchInApp` for Siri AI, so adopting it now is
//  forward-compatible groundwork.
//
//  Conforms to the `ShowInAppSearchResultsIntent` protocol (iOS 17.2)
//  DIRECTLY, without the `@AppIntent(schema: .system.search)` macro: in
//  the iOS 26.5 SDK that macro's generated extension demands a
//  nonisolated/Sendable conformance that a MainActor-defaulted struct
//  cannot provide ("main actor-isolated conformance … cannot satisfy
//  conformance requirement for a 'Sendable' type parameter 'Self'"),
//  while the plain protocol conformance compiles exactly like
//  `OpenTripIntent`'s identical `{ get set }` parameter shape. The
//  protocol is what powers the system-search integration; the macro only
//  adds assistant-schema metadata tagging, inert until Siri AI.
//  Re-attempt the macro against the iOS 27 SDK.
//
//  Unlike `SearchTripsIntent` (which answers inline with dialog +
//  snippet), this intent's contract is "open the app showing results":
//  perform() routes the query into the Trips tab's search field via
//  `TripsTabRouter.requestedSearchQuery`, driving the same fuzzy → FM
//  dual-path search the user would get typing it.
//

import AppIntents
import Foundation

// MainActor-isolated (target default; `@Parameter` forbids `nonisolated`).
struct ShowTripSearchResultsIntent: ShowInAppSearchResultsIntent {

    static let title: LocalizedStringResource = "Search Trips in App"
    static let description = IntentDescription(
        "Opens TravelLog showing trips that match a search.",
        categoryName: "Trips"
    )

    static let searchScopes: [StringSearchScope] = [.general]

    @Parameter(title: "Criteria")
    var criteria: StringSearchCriteria

    static var parameterSummary: some ParameterSummary {
        Summary("Show trips matching \(\.$criteria)")
    }

    func perform() async throws -> some IntentResult {
        let term = criteria.term
        await MainActor.run {
            TripsTabRouter.shared.requestSearch(term)
        }
        return .result()
    }
}
