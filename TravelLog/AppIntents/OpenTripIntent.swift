//
//  OpenTripIntent.swift
//  TravelLog
//
//  Opens a specific trip's detail view. This is what makes a Spotlight
//  entity result tappable-through-to-content (the system runs a matching
//  `OpenIntent` when one exists), and what lets Shortcuts/Siri say
//  "open my Paris trip".
//
//  Navigation rides the existing cross-tab router: perform() sets
//  `TripsTabRouter.requestedTripID`; `MainTabView` switches to the Trips
//  tab; `TripsListView` resolves the UUID against the store and pushes
//  `TripDetailView`. A UUID that no longer resolves (churned ongoing-trip
//  identity, post-reclassify Spotlight staleness) degrades to just opening
//  the Trips tab.
//

import AppIntents
import Foundation

// MainActor-isolated (target default): `@Parameter` is a mutable stored
// property, which `nonisolated` types forbid.
struct OpenTripIntent: AppIntent, OpenIntent {

    static let title: LocalizedStringResource = "Open Trip"
    static let description = IntentDescription(
        "Opens a trip in TravelLog.",
        categoryName: "Trips"
    )

    @Parameter(title: "Trip")
    var target: TripEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$target)")
    }

    func perform() async throws -> some IntentResult {
        await TripsTabRouter.shared.requestTrip(target.id)
        return .result()
    }
}
