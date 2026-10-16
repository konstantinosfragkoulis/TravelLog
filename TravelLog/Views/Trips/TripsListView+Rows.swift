//
//  TripsListView+Rows.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import SwiftUI
import TipKit
import UIKit
import SwiftData
import WidgetKit
import os.log

// MARK: - Active Trip Row

/// A prominent row for an ongoing trip with the accent "Now" pill.
struct ActiveTripRow: View {
    let trip: Trip
    var caption: TripsListView.MatchCaption?
    /// The temporary-home question, from the list's cache (never computed here).
    var suggestion: TemporaryHomeSuggestion.Candidate?
    var onSetUp: (TemporaryHomeSuggestion.Candidate) -> Void = { _ in }
    var onNotNow: (TemporaryHomeSuggestion.Candidate) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(trip.hasUsableDisplayName ? trip.displayName : String(localized: "trips.active-name.fallback", defaultValue: "Trip in Progress", comment: "Fallback title for an ongoing trip without a usable name."))
                    .font(.headline)

                Spacer()

                if !trip.countryFlags.isEmpty {
                    Text(trip.countryFlags)
                        .font(.title3)
                }
            }

            HStack(spacing: 6) {
                StatusPill(label: Text("Now"))

                // Count calendar-date boundaries rather than elapsed 24-hour intervals.
                // Same civil-day rule as the Current Trip widget: inclusive
                // Gregorian days between the departure stay's zone and the
                // latest stay's zone, so the list and the widget agree.
                // Minute ticks land on every zone's midnight, so the day flips with no store write.
                // A tick can land after a background delete and before the parent
                // filters the row; `isDeleted` is the one safe read on an invalidated model.
                TimelineView(.everyMinute) { context in
                    if !trip.isDeleted, trip.modelContext != nil {
                        let displayDay = TripsListView.ongoingDisplayDay(for: trip, now: context.date)
                        Text(displayDay == 1
                             ? String(localized: "trips.active-day.one", defaultValue: "Day \(displayDay, format: .number.grouping(.never))", comment: "Ongoing trip row label for its first day.")
                             : String(localized: "trips.active-day.other", defaultValue: "Day \(displayDay, format: .number.grouping(.never))", comment: "Ongoing trip row label for a later day."))
                    }
                }

                Text(verbatim: "·")

                Text("Since \(trip.startDate.formatted(date: .abbreviated, time: .omitted))")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            matchCaptionLine(caption)

            stayCountBadges(for: trip)

            if let suggestion {
                TemporaryHomeSuggestionLine(
                    candidate: suggestion,
                    onSetUp: { onSetUp(suggestion) },
                    onNotNow: { onNotNow(suggestion) })
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Temporary Home Suggestion

/// Reruns the trips list's suggestions on stay changes while `isActive`.
/// The token read lives here, so a stay change redraws this empty view, not the list.
struct TemporaryHomeSuggestionStayObserver: View {
    let isActive: Bool
    let onChange: () -> Void

    var body: some View {
        Color.clear
            .task(id: TripsListView.suggestionStayToken(followsStays: isActive)) {
                guard isActive else { return }
                onChange()
            }
    }
}

/// "Living in Brussels for now?" with Set Up and Not Now, on an open trip's
/// row and at the top of a trip's detail. Pure display over the candidate.
struct TemporaryHomeSuggestionLine: View {
    let candidate: TemporaryHomeSuggestion.Candidate
    let onSetUp: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(Self.text(placeName: candidate.placeName, isOngoing: candidate.isOngoing))
            } icon: {
                Image(systemName: "house.and.flag")
                    .foregroundStyle(.tint)
            }
            .font(.caption)

            // Borderless, so a row's link does not swallow the taps.
            HStack(spacing: 10) {
                Button {
                    onSetUp()
                } label: {
                    Text(String(
                        localized: "temporary-home.suggestion.set-up",
                        defaultValue: "Set Up",
                        comment: "Button on the temporary home suggestion that opens the form for a new temporary home, prefilled from the trip."
                    ))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(.tint, in: .capsule)
                    .foregroundStyle(.white)
                }
                .buttonStyle(.borderless)

                Button {
                    onNotNow()
                } label: {
                    Text(String(
                        localized: "temporary-home.suggestion.not-now",
                        defaultValue: "Not Now",
                        comment: "Button on the temporary home suggestion that hides it for this trip on this device."
                    ))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(.quaternary, in: .capsule)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    /// The question: ongoing "Living in Brussels for now?", completed "Lived
    /// in Brussels for a while?", then why. Without a city it asks about
    /// "here" (ongoing) or "there" (completed).
    static func text(placeName: String?, isOngoing: Bool) -> String {
        if let placeName, !placeName.isEmpty {
            return isOngoing
                ? String(localized: "temporary-home.suggestion.ongoing.place", defaultValue: "Living in \(placeName) for now? Set up a temporary home so your trips from there count on their own.", comment: "Suggestion on an ongoing trip that mostly stays in one city; the placeholder is the city. A temporary home makes trips from there separate trips.")
                : String(localized: "temporary-home.suggestion.completed.place", defaultValue: "Lived in \(placeName) for a while? Set up a temporary home so your trips from there count on their own.", comment: "Suggestion on a long completed trip that mostly stayed in one city; the placeholder is the city. A temporary home makes trips from there separate trips.")
        }
        return isOngoing
            ? String(localized: "temporary-home.suggestion.ongoing.here", defaultValue: "Living here for now? Set up a temporary home so your trips from here count on their own.", comment: "Suggestion on an ongoing trip that mostly stays in one place whose city is unknown. A temporary home makes trips from there separate trips.")
            : String(localized: "temporary-home.suggestion.completed.there", defaultValue: "Lived there for a while? Set up a temporary home so your trips from there count on their own.", comment: "Suggestion on a long completed trip that mostly stayed in one place whose city is unknown. A temporary home makes trips from there separate trips.")
    }
}

/// Why a search row matched, when the row does not already show it. The
/// text joins the row's combined accessibility label; the symbol is decorative.
@ViewBuilder
private func matchCaptionLine(_ caption: TripsListView.MatchCaption?) -> some View {
    if let caption {
        HStack(spacing: 4) {
            Image(systemName: caption.systemImage)
                .accessibilityHidden(true)
            Text(caption.text)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// Destination and transit counts shared by the trip rows: small neutral
/// chips, told apart by their words and icons rather than by colour.
@ViewBuilder
private func stayCountBadges(for trip: Trip) -> some View {
    HStack(spacing: 6) {
        let destCount = trip.destinationCount
        let transitCount = trip.transitCount

        if destCount > 0 {
            AppChip(
                label: Text(destCount == 1
                    ? String(localized: "trips.destination-count.one", defaultValue: "\(destCount, format: .number.grouping(.never)) destination", comment: "Trip row badge for one destination.")
                    : String(localized: "trips.destination-count.other", defaultValue: "\(destCount, format: .number.grouping(.never)) destinations", comment: "Trip row badge for multiple destinations.")),
                systemImage: "mappin",
                small: true)
        }

        if transitCount > 0 {
            AppChip(
                label: Text(transitCount == 1
                    ? String(localized: "trips.transit-count.one", defaultValue: "\(transitCount, format: .number.grouping(.never)) transit", comment: "Trip row badge for one transit stop.")
                    : String(localized: "trips.transit-count.other", defaultValue: "\(transitCount, format: .number.grouping(.never)) transits", comment: "Trip row badge for multiple transit stops.")),
                systemImage: "arrow.triangle.swap",
                small: true)
        }
    }
}

// MARK: - Trip Row

/// A standard row for a completed trip.
struct TripRow: View {
    let trip: Trip
    var caption: TripsListView.MatchCaption?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(trip.displayName)
                    .font(.headline)

                Spacer()

                if !trip.countryFlags.isEmpty {
                    Text(trip.countryFlags)
                        .font(.title3)
                }
            }

            HStack(spacing: 6) {
                Text(formattedDateRange)

                if let days = trip.durationDays {
                    Text(verbatim: "·")
                    Text(days == 1
                          ? String(localized: "trips.duration-days.one", defaultValue: "\(days, format: .number.grouping(.never)) day", comment: "Completed trip row duration of one day.")
                          : String(localized: "trips.duration-days.other", defaultValue: "\(days, format: .number.grouping(.never)) days", comment: "Completed trip row duration of multiple days."))
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            matchCaptionLine(caption)

            stayCountBadges(for: trip)
        }
        .padding(.vertical, 4)
    }

    private var formattedDateRange: String {
        let start = trip.startDate.formatted(date: .abbreviated, time: .omitted)
        if let endDate = trip.endDate {
            if Calendar.current.isDate(trip.startDate, inSameDayAs: endDate) { return start }
            return (trip.startDate..<endDate).formatted(
                Date.IntervalFormatStyle(date: .abbreviated, time: .omitted)
            )
        }
        return String(localized: "trips.date-range.now", defaultValue: "\(start) - now", comment: "Open trip date range ending now; preserve the English hyphen glyph.")
    }
}
