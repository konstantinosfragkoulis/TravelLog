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
    static let description = IntentDescription(
        "Tells you the next upcoming trip detected from your calendar.",
        categoryName: "Trips"
    )

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // The container initializer records the mode, so open it first.
        let container = AppDelegate.modelContainer
        try IntentDataError.requirePersistentStore(AppDelegate.containerMode.isPersistent)
        let context = ModelContext(container)
        let now = Date.now

        // Same reads as the Upcoming Trip widget, then the same pipeline as
        // the Trips-list card: chain rows into journeys (low-confidence legs
        // ride along), surface medium+ only, and drop a started journey an
        // ongoing trip already covers. A failed read is never "no upcoming
        // trips" and never a journey the app would not name.
        let inputs: PlannedTripChainer.StoreInputs
        do {
            inputs = try PlannedTripChainer.storeInputs(in: context, now: now)
        } catch {
            throw IntentDataError.mapped(error, intent: "Next Trip")
        }
        let legs = inputs.legs
        let homeNames = inputs.homeNames
        let ongoingTripStartDates = inputs.ongoingTripStartDates

        // Chain off-main: legs/homeNames are Sendable value
        // types, and a busy 180-day calendar shouldn't make Siri wait on
        // MainActor row-chaining.
        let journeyResult = await Task.detached {
            PlannedTripChainer.nextJourney(
                from: legs,
                homeNames: homeNames,
                now: now,
                ongoingTripStartDates: ongoingTripStartDates
            )
        }.value
        guard let journey = journeyResult
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

        let dates = (journey.startDate..<max(journey.startDate, journey.endDate))
            .formatted(Date.IntervalFormatStyle().day().month(.wide))
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
}
