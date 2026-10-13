//
//  PlannedTripCard.swift
//  TravelLog
//

import SwiftUI

/// One row for a calendar-detected upcoming JOURNEY, possibly many chained
/// calendar events ("Trip to Cephalonia" + "Boat: … from Cephalonia to Ios" + the
/// return ticket render as one "Cephalonia → Ios" card; see `PlannedTripChainer`).
/// Pure display over the `PlannedJourney` value; the dismiss action is
/// injected by `TripsListView`, which owns the underlying `PlannedTrip` rows.
struct PlannedTripCard: View {

    let journey: PlannedJourney
    /// Forecast from the journey's anchor row; nil until resolved
    /// coordinates exist and the trip is within WeatherKit's ~10-day horizon.
    let forecast: PlannedTripForecast?
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(journey.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(dateRangeText)
                    Text(verbatim: "·")
                    // Reread the clock each minute: "in 3 hours" and "now" age with no store write.
                    TimelineView(.everyMinute) { _ in
                        Text(relativeStartText)
                            .foregroundStyle(.tint)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if journey.legCount > 1 {
                    Label(String(localized: "planned-trip.calendar-events.other", defaultValue: "\(journey.legCount, format: .number.grouping(.never)) calendar events", comment: "Planned journey source count for multiple calendar events."), systemImage: "link")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)

            if let day = forecastDay {
                VStack(spacing: 2) {
                    Image(systemName: (StayWeather.Condition(rawValue: day.conditionRaw) ?? .unknown).systemImage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("\(UnitsFormatter.formatTemperature(day.minTemperatureC))–\(UnitsFormatter.formatTemperature(day.maxTemperatureC))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            dismissButton
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            dismissButton
        }
    }

    private var dismissButton: some View {
        Button(role: .destructive, action: onDismiss) {
            Label("Dismiss", systemImage: "xmark.circle")
        }
    }

    private var dateRangeText: String {
        journey.displayDateRange().formatted(
            Date.IntervalFormatStyle().day().month(.abbreviated)
        )
    }

    /// The forecast day closest to the journey's start (first covered day).
    private var forecastDay: PlannedTripForecast.Day? {
        forecast?.days.min {
            abs($0.date.timeIntervalSince(journey.startDate)) < abs($1.date.timeIntervalSince(journey.startDate))
        }
    }

    private var relativeStartText: String {
        if journey.startDate <= Date.now {
            return String(localized: "planned-trip.relative-start.now", defaultValue: "now", comment: "Planned trip relative start label when the journey has already begun.")
        }
        return journey.startDate.formatted(
            .relative(presentation: .named, unitsStyle: .wide)
        )
    }
}
