//
//  TripsTabRouter.swift
//  TravelLog
//
//  In-memory cross-tab routing for the Trips tab. Lets one tab (Stats)
//  request a navigation to the Trips tab with a pre-applied filter
//  without needing Binding plumbing through every view in between.
//  Also owns the Trips tab's navigation path, so a request lands on the
//  list itself, never under a page the user had opened.
//
//  Pattern mirrors `PinnedTripsStorage.shared` (an `@Observable
//  @MainActor` singleton). The router is NOT persisted — it's a
//  short-lived signal consumed in the same scenePhase as it's set.
//

import Foundation
import Observation
import SwiftData
import os.log

/// A page on the Trips tab's navigation stack.
enum TripsRoute: Hashable {
    /// A trip the user opened from the list.
    case trip(Trip)
    /// A trip a request opened (`TripsTabRouter.requestTrip`). `request`
    /// differs per request, so it never equals a page already on the stack:
    /// opening the trip on screen again still drops what was pushed above it.
    case requestedTrip(Trip, request: Int)
    /// A temporary home's page, by its card's id.
    case temporaryHome(UUID)

    var trip: Trip? {
        switch self {
        case .trip(let trip), .requestedTrip(let trip, _): trip
        case .temporaryHome: nil
        }
    }
}

/// Cross-tab navigation signal for the Trips tab.
///
/// Set `requestedCountryCode` from anywhere (typically the Stats tab's
/// country list); `MainTabView` observes it and switches the active
/// tab to "trips"; `TripsListView` then consumes it in `.task`,
/// replaces its `filters.countryCodes` with the single requested code,
/// persists, and clears the router.
///
/// **Why not a URL deep link?** `MainTabView` already has an
/// `onOpenURL` handler for `travellog://trips` / `travellog://stats`.
/// We could extend that with `?country=GR` style params, but:
///   - URLs require stringly-typed parsing and round-tripping for an
///     in-process signal that's already strongly typed.
///   - `onOpenURL` is for OS-initiated opens (deep links from outside
///     the app). Internal navigation should use SwiftUI's data flow.
///   - The router survives if we later add multi-window iPad scenes,
///     where deep links would otherwise need a window selector.
///
/// **Lifetime semantics.** The router is single-set / single-consume.
/// Setting `requestedCountryCode` is a one-shot signal — consumers
/// should clear it after applying so the same value doesn't re-fire
/// on every subsequent `.task` invocation. The router is not
/// persisted across app launches.
@MainActor
@Observable
final class TripsTabRouter {
    static let shared = TripsTabRouter()

    /// ISO 3166-1 alpha-2 code. When non-nil, requests that the Trips
    /// tab become active with `TripFilters.countryCodes = [this code]`.
    /// `MainTabView` watches this via `.onChange` to switch tabs;
    /// `TripsListView` consumes it via `.task`, applies the filter,
    /// and sets this back to nil.
    var requestedCountryCode: String?

    /// Trip UUID to push the detail view for. Set by `OpenTripIntent`
    /// (Spotlight result tap, Siri, Shortcuts); same single-set /
    /// single-consume semantics as `requestedCountryCode`. `TripsListView`
    /// resolves it against the store — a UUID that no longer exists
    /// (churned ongoing-trip identity, stale Spotlight entry) degrades to
    /// just landing on the Trips tab.
    var requestedTripID: UUID?

    /// The physical row `requestedTripID` names, when the request came from
    /// an entity built from one row (a search result): that row opens, or
    /// nothing does. nil opens the UUID's representative
    /// (`TripEntityFetcher.representative(of:)`). Set and cleared with it.
    private(set) var requestedTripRow: PersistentIdentifier?

    /// Search text to pre-fill the Trips tab's search field with. Set by
    /// `ShowTripSearchResultsIntent` (the `.system.search` schema hook —
    /// "open the app showing results for this query"); same single-set /
    /// single-consume semantics as the other signals.
    var requestedSearchQuery: String?

    /// The Trips tab's navigation path (`MainTabView` binds its stack to
    /// it). Every request returns it to the list first, so a filter or a
    /// search shows on the list and a requested trip opens straight on it,
    /// whatever the user had pushed, however deep: the list's rows push
    /// values, so any page above them sits on one of these routes.
    var path: [TripsRoute] = []

    /// Advances with each trip request; tags its `.requestedTrip` route.
    private(set) var tripRequestCount = 0

    private let logger = Logger(subsystem: "com.travellog.app", category: "TripsTabRouter")

    private init() {}

    /// Sets `requestedCountryCode`. Logged for telemetry / debugging.
    ///
    /// The code itself default-redacts: an explicit `privacy: .public` would
    /// override os.log's redaction and write a coarse location signal — which
    /// countries this user travels to — verbatim into the unified log,
    /// readable by anything with log access. For a
    /// privacy-first travel journal that is the wrong default. The event
    /// itself staying public is what makes the line useful for debugging.
    func requestCountryFilter(_ code: String) {
        logger.debug("Request country filter from cross-tab tap: \(code)")
        popToList()
        requestedCountryCode = code
    }

    /// Sets `requestedTripID`. Logged for telemetry / debugging.
    ///
    /// The id default-redacts for the same reason: it is a stable device-local
    /// identifier that correlates log lines to one specific trip.
    func requestTrip(_ id: UUID, row: PersistentIdentifier? = nil) {
        logger.debug("Request trip detail from App Intent: \(id.uuidString)")
        popToList()
        tripRequestCount &+= 1
        requestedTripRow = row
        requestedTripID = id
    }

    /// Sets `requestedSearchQuery`. Logged for telemetry / debugging.
    func requestSearch(_ query: String) {
        logger.debug("Request trip search from App Intent (\(query.count, privacy: .public) chars)")
        popToList()
        requestedSearchQuery = query
    }

    /// Opens the trip a request resolved to, alone on the list.
    func showRequestedTrip(_ trip: Trip) {
        path = [.requestedTrip(trip, request: tripRequestCount)]
    }

    /// Drops the first route `isGone` matches and every page above it:
    /// a trip that left the store takes its page with it.
    func popRoutes(from isGone: (TripsRoute) -> Bool) {
        guard let index = path.firstIndex(where: isGone) else { return }
        path.removeSubrange(index...)
    }

    private func popToList() {
        if !path.isEmpty { path = [] }
    }

    /// Clears any pending request. Called by the consumer (`TripsListView`)
    /// after applying the filter so the router is ready for the next
    /// cross-tab signal.
    func clear() {
        requestedCountryCode = nil
    }

    /// Clears any pending trip-open request; separate from `clear()` so
    /// the two signals can't clobber each other mid-consume.
    func clearTripRequest() {
        requestedTripID = nil
        requestedTripRow = nil
    }

    /// Clears any pending search request; separate for the same
    /// no-cross-clobber reason.
    func clearSearchRequest() {
        requestedSearchQuery = nil
    }
}
