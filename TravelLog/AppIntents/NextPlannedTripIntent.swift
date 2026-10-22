//
//  NextPlannedTripIntent.swift
//  TravelLog
//
//  "When's my next trip?" — read-only App Intent over the calendar future
//  lane. Answers from `PlannedTrip` rows chained into journeys.
//

import AppIntents
import Foundation
import SwiftData

// MainActor-isolated (target default), like every intent here. The fetch is
// a handful of PlannedTrip/Home rows — no off-main hop needed (unlike
// TravelStatsIntent's full-table aggregations). A failed read throws
// IntentDataError instead of answering.
struct NextPlannedTripIntent: AppIntent {

    static let title: LocalizedStringResource = "Next Trip"
    /// Travel history is personal, so a locked device must be unlocked first.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static let description = IntentDescription(
        "Tells you the next upcoming trip detected from your calendar.",
        categoryName: "Trips"
    )

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // The container initializer records the mode, so open it first.
        let container = AppDelegate.modelContainer
        try IntentDataError.requirePersistentStore(AppDelegate.containerMode.isPersistent)
        let now = Date.now
        guard let journey = try await Self.nextJourney(container: container, now: now)
        else {
            let dialog: IntentDialog
            if CalendarEnricher.hasReadAccess {
                let message = String(
                    localized: "app-intent.next-trip.none",
                    defaultValue: "No upcoming trips found in your calendar.",
                    comment: "Siri response when no future calendar trip was found."
                )
                dialog = IntentDialog("\(message)")
            } else {
                let message = String(
                    localized: "app-intent.next-trip.calendar-not-connected",
                    defaultValue: "Calendar isn't connected. You can connect it in Travel Log's settings to detect upcoming trips.",
                    comment: "Siri response when calendar access is unavailable."
                )
                dialog = IntentDialog("\(message)")
            }
            return .result(dialog: dialog)
        }

        let dates = DateRangeText.format(
            journey.displayDateRange(), Date.IntervalFormatStyle().day().month(.wide))
        let dialog: IntentDialog
        if journey.startDate <= now {
            let message = String(
                localized: "app-intent.next-trip.current",
                defaultValue: "You're on your \(journey.displayName) trip right now (\(dates)).",
                comment: "Siri response when the next planned trip is already underway."
            )
            dialog = IntentDialog("\(message)")
        } else {
            let lead = journey.startDate.formatted(.relative(presentation: .named, unitsStyle: .wide))
            let message = String(
                localized: "app-intent.next-trip.upcoming",
                defaultValue: "Your next trip is \(journey.displayName) \(lead) (\(dates)).",
                comment: "Siri response describing the next planned trip."
            )
            dialog = IntentDialog("\(message)")
        }
        return .result(dialog: dialog)
    }

    /// The journey to speak. Same reads as the Upcoming Trip widget, then
    /// the same pipeline as the Trips-list card: chain rows into journeys
    /// (low-confidence legs ride along), surface medium+ only, and drop a
    /// started journey an ongoing trip already covers. A failed read is
    /// never "no upcoming trips" and never a journey the app would not name.
    /// A deletion that clears the Stats snapshot (Delete All Data, Delete
    /// Calendar Data) while it chains revokes the answer: it throws rather
    /// than speak a deleted journey.
    static func nextJourney(
        container: ModelContainer,
        now: Date,
        clearGeneration: Int = StatsSnapshotStore.clearGeneration
    ) async throws -> PlannedJourney? {
        let inputs: PlannedTripChainer.StoreInputs
        do {
            inputs = try PlannedTripChainer.storeInputs(in: ModelContext(container), now: now)
        } catch {
            throw IntentDataError.mapped(error, intent: "Next Trip")
        }
        let legs = inputs.legs
        let homeNames = inputs.homeNames
        let ongoingTripStartDates = inputs.ongoingTripStartDates

        // Chain off-main: legs/homeNames are Sendable value
        // types, and a busy 180-day calendar shouldn't make Siri wait on
        // MainActor row-chaining.
        let journey = await Task.detached {
            PlannedTripChainer.nextJourney(
                from: legs,
                homeNames: homeNames,
                now: now,
                ongoingTripStartDates: ongoingTripStartDates
            )
        }.value
        try TripIntentSearch.refuseIfRevoked(since: clearGeneration)
        return journey
    }
}
