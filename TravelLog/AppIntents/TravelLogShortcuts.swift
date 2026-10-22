//
//  TravelLogShortcuts.swift
//  TravelLog
//
//  App Shortcuts — zero-setup Siri phrases available as soon as the app
//  is installed (the framework auto-detects this provider; no
//  registration code). Every phrase must contain `.applicationName`.
//
//  These work with classic Siri/Shortcuts/Spotlight on iOS 26 — including
//  in the EU, where Siri AI itself is delayed — and are the same intents
//  Siri AI's orchestrator invokes on iOS 27.
//

import AppIntents

nonisolated struct TravelLogShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SearchTripsIntent(),
            phrases: [
                "Search trips in \(.applicationName)",
                "Find a trip in \(.applicationName)",
                "Search my \(.applicationName) journal",
            ],
            shortTitle: "Search Trips",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: TravelStatsIntent(),
            phrases: [
                "Travel stats in \(.applicationName)",
                "My \(.applicationName) stats",
                "How much have I traveled in \(.applicationName)",
            ],
            shortTitle: "Travel Stats",
            systemImageName: "chart.bar.fill"
        )
        AppShortcut(
            intent: WhereWasIIntent(),
            phrases: [
                "Where was I in \(.applicationName)",
                "Ask \(.applicationName) where I was",
            ],
            shortTitle: "Where Was I",
            systemImageName: "calendar"
        )
        AppShortcut(
            intent: NextPlannedTripIntent(),
            phrases: [
                "When's my next trip in \(.applicationName)",
                "Next trip in \(.applicationName)",
                "What's my upcoming trip in \(.applicationName)",
            ],
            shortTitle: "Next Trip",
            systemImageName: "calendar.badge.clock"
        )
        AppShortcut(
            intent: FavoriteTripIntent(),
            phrases: [
                "Favorite a trip in \(.applicationName)",
                "Add a \(.applicationName) trip to favorites",
            ],
            shortTitle: "Favorite Trip",
            systemImageName: "star.fill"
        )
    }
}
