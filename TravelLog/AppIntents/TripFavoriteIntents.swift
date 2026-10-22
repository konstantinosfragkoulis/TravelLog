//
//  TripFavoriteIntents.swift
//  TravelLog
//
//  Favorite / unfavorite a trip from Siri, Shortcuts, or (later) Siri AI
//  ("add that one to favorites"). Writes go through `PinnedTripsStorage`
//  (iCloud KVS) — NOT the SwiftData store, so no `PipelineGate` routing
//  is needed; the storage class is the same one the trip context menu
//  and detail-view star use, so state stays consistent everywhere.
//
//  A stale `TripEntity` UUID (churned ongoing trip, post-reclassify) pins
//  an ID no trip carries — harmless by construction: pins are a UUID set
//  that simply never matches, the same exposure the in-app pin UI accepts.
//

import AppIntents
import Foundation

// MainActor-isolated (target default; `@Parameter` forbids `nonisolated`).
struct FavoriteTripIntent: AppIntent {

    static let title: LocalizedStringResource = "Favorite Trip"
    /// Travel history is personal, so a locked device must be unlocked first.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static let description = IntentDescription(
        "Adds a trip to your Favorites.",
        categoryName: "Trips"
    )

    @Parameter(title: "Trip")
    var trip: TripEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Favorite \(\.$trip)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await PinnedTripsStorage.shared.pin(trip.tripID)
        let message = String(
            localized: "app-intent.favorite-trip.added",
            defaultValue: "Added “\(trip.title)” to Favorites.",
            comment: "Siri confirmation after favoriting a trip."
        )
        return .result(dialog: IntentDialog("\(message)"))
    }
}

struct UnfavoriteTripIntent: AppIntent {

    static let title: LocalizedStringResource = "Unfavorite Trip"
    /// Travel history is personal, so a locked device must be unlocked first.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static let description = IntentDescription(
        "Removes a trip from your Favorites.",
        categoryName: "Trips"
    )

    @Parameter(title: "Trip")
    var trip: TripEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Unfavorite \(\.$trip)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await PinnedTripsStorage.shared.unpin(trip.tripID)
        let message = String(
            localized: "app-intent.favorite-trip.removed",
            defaultValue: "Removed “\(trip.title)” from Favorites.",
            comment: "Siri confirmation after removing a trip from Favorites."
        )
        return .result(dialog: IntentDialog("\(message)"))
    }
}
