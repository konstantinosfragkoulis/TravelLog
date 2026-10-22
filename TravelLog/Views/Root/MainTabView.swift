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

    /// Trip files waiting for their preview.
    private let sharedTripInbox = SharedTripInbox.shared

    /// Settings navigation, so an opened backup can show Import & Export.
    private let settingsRouter = SettingsRouter.shared

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Trips", systemImage: "airplane", value: "trips") {
                // A request from another tab returns this stack to the list (`TripsTabRouter.path`).
                NavigationStack(path: Binding(get: { tripsRouter.path }, set: { tripsRouter.path = $0 })) {
                    TripsListView()
                }
            }

            Tab("Map", systemImage: "hexagon", value: "map") {
                NavigationStack { HexMapView() }
            }

            Tab("Stats", systemImage: "chart.bar.fill", value: "stats") {
                NavigationStack { StatsView() }
            }

            Tab("Settings", systemImage: "gear", value: "settings") {
                NavigationStack(path: Binding(get: { settingsRouter.path }, set: { settingsRouter.path = $0 })) {
                    SettingsView()
                }
            }
        }
        .onOpenURL { open($0) }
        // A file opened while setup was unfinished (`OpenedFileHold`).
        .task {
            if let held = OpenedFileHold.take() { open(held) }
        }
        // Cross-tab navigation: when any other view sets a country code
        // on the router, jump to the Trips tab. `TripsListView` does the
        // actual filter application + router clear in its own `.task`
        // (it owns the `filters` state). We deliberately do NOT clear
        // the router here — that would race with TripsListView's
        // consumer if it runs after this onChange.
        .sheet(item: Binding(get: { sharedTripInbox.pending }, set: { sharedTripInbox.pending = $0 })) { pending in
            SharedTripPreviewSheet(file: pending.file)
        }
        .alert(String(localized: "shared-trip.open-error.title", defaultValue: "Can't Open Trip",
                      comment: "Alert title when a shared trip file cannot be opened."),
               isPresented: Binding(get: { sharedTripInbox.openError != nil },
                                    set: { if !$0 { sharedTripInbox.openError = nil } })) {
            Button(String(localized: "common.ok", defaultValue: "OK", comment: "Generic OK button."), role: .cancel) {}
        } message: {
            Text(sharedTripInbox.openError ?? "")
        }
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

    private func open(_ url: URL) {
        switch OpenedFile.kind(of: url) {
        case .trip:
            // A trip file from Files, AirDrop, Messages or Mail.
            sharedTripInbox.open(url)
        case .backup:
            // Never restored here: Import & Export previews it and asks first.
            selectedTab = "settings"
            settingsRouter.openBackup(url)
        case .other:
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
    }
}
