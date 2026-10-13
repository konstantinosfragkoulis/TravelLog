//
//  MainTabView.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//


import SwiftUI
 
/// The main tab bar interface shown after onboarding.
///
/// Four-tab layout:
/// 1. **Trips** - AI-classified trips with detail view (primary)
/// 2. **Map** - H3 hex coverage visualization
/// 3. **Stats** - aggregate statistics dashboard
/// 4. **Settings** - home/routine management, status dashboard, data tools
struct MainTabView: View {

    @State private var selectedTab = "trips"

    /// Cross-tab routing signal. When something elsewhere in the app
    /// requests a Trips filter (currently: tapping a country in the
    /// Stats tab's country list), we observe the router's
    /// `requestedCountryCode` and jump to the Trips tab. `TripsListView`
    /// then consumes the request in its `.task` and clears the router.
    /// See `TripsTabRouter` for the full design rationale.
    private let tripsRouter = TripsTabRouter.shared

    /// Stats → Map hex-highlight signal; same pattern as `tripsRouter`.
    /// `HexMapView` consumes the request and clears the router.
    private let mapRouter = MapTabRouter.shared

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Trips", systemImage: "airplane", value: "trips") {
                NavigationStack { TripsListView() }
            }

            Tab("Map", systemImage: "hexagon", value: "map") {
                NavigationStack { HexMapView() }
            }

            Tab("Stats", systemImage: "chart.bar.fill", value: "stats") {
                NavigationStack { StatsView() }
            }

            Tab("Settings", systemImage: "gear", value: "settings") {
                NavigationStack { SettingsView() }
            }
        }
        .onOpenURL { url in
            guard url.scheme == "travellog" else { return }
            switch url.host {
            case "trips":
                selectedTab = "trips"
            case "stats":
                selectedTab = "stats"
            default:
                break
            }
        }
        // Cross-tab navigation: when any other view sets a country code
        // on the router, jump to the Trips tab. `TripsListView` does the
        // actual filter application + router clear in its own `.task`
        // (it owns the `filters` state). We deliberately do NOT clear
        // the router here — that would race with TripsListView's
        // consumer if it runs after this onChange.
        .onChange(of: tripsRouter.requestedCountryCode) { _, newCode in
            if newCode != nil {
                selectedTab = "trips"
            }
        }
        // Trip-open requests from App Intents (Spotlight / Siri /
        // Shortcuts): same contract as the country-filter signal above —
        // switch the tab here, let `TripsListView` resolve + push + clear.
        // Cold launches land on "trips" by default, so no `initial:` is
        // needed; `TripsListView`'s consumer handles the set-before-observe
        // case with its own `initial: true`.
        .onChange(of: tripsRouter.requestedTripID) { _, newID in
            if newID != nil {
                selectedTab = "trips"
            }
        }
        .onChange(of: tripsRouter.requestedSearchQuery) { _, newQuery in
            if newQuery != nil {
                selectedTab = "trips"
            }
        }
        .onChange(of: mapRouter.requestedHighlight) { _, newRequest in
            if newRequest != nil {
                selectedTab = "map"
            }
        }
    }
}
