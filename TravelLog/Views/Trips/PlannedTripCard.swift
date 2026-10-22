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
    /// The legs' resolved countries in leg order; empty until geocoded.
    var countryCodes: [String] = []
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // The trip rows' grammar: the flag deck, a headline title, the
            // countries and dates as one quiet line, then the countdown.
            TripLeadRow(codes: countryCodes) {
                Text(journey.displayName)
                    .font(.headline)
                    .lineLimit(2)

                countriesAndDates
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.top, 3)

                // Upcoming is a moment that matters: the saffron countdown.
                // Reread the clock each minute: "in 3 hours" and "now" age with no store write.
                TimelineView(.everyMinute) { context in
                    HStack(spacing: 5) {
                        Image(systemName: "calendar.badge.clock")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AppTheme.saffron)
                            .accessibilityHidden(true)
                        Text(relativeStartText(now: context.date))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AppTheme.saffronText)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 9)
                    .frame(minHeight: 24)
                    .background(AppTheme.saffronSoft, in: .capsule)
                }
                .padding(.top, 8)

                if journey.legCount > 1 {
                    Label(String(localized: "planned-trip.calendar-events.other", defaultValue: "\(journey.legCount, format: .number.grouping(.never)) calendar events", comment: "Planned journey source count for multiple calendar events."), systemImage: "link")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
            }

            Spacer(minLength: 0)

            if let day = forecastDay {
                VStack(spacing: 2) {
                    // Weather colour carries the condition, as in the timeline.
                    Image(systemName: (StayWeather.Condition(rawValue: day.conditionRaw) ?? .unknown).systemImage)
                        .weatherGlyph()
                        .font(.title3)
                    Text(String(localized: "planned-trip.forecast.temperature-range", defaultValue: "\(UnitsFormatter.formatTemperature(day.minTemperatureC)) to \(UnitsFormatter.formatTemperature(day.maxTemperatureC))", comment: "Forecast low and high temperature on a planned trip card: low, then high."))
                        .font(AppTheme.stat(.caption, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .alignmentGuide(.listRowSeparatorLeading) { _ in FlagDeck.width + FlagDeck.gap }
        .wholePointHeight()
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

    /// "Morocco · 21 to 26 Nov" on one line when it fits; otherwise the
    /// countries, then the dates on their own line (never a stray "·").
    @ViewBuilder
    private var countriesAndDates: some View {
        if let names = TripRowText.countryLine(countryCodes) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Text(names)
                    Text(verbatim: "·").accessibilityHidden(true)
                    Text(dateRangeText)
                }
                .fixedSize()
                VStack(alignment: .leading, spacing: 0) {
                    Text(names)
                    Text(dateRangeText)
                }
            }
        } else {
            Text(dateRangeText)
        }
    }

    private var dateRangeText: String {
        let range = journey.displayDateRange()
        return TripDisplayText.range(from: range.lowerBound, to: range.upperBound, includeYear: false)
    }

    /// The forecast day closest to the journey's start (first covered day).
    private var forecastDay: PlannedTripForecast.Day? {
        forecast?.days.min {
            abs($0.date.timeIntervalSince(journey.startDate)) < abs($1.date.timeIntervalSince(journey.startDate))
        }
    }

    /// "in 36 days"; within the start's own day the finer "in 3 hours";
    /// "now" once it has begun.
    private func relativeStartText(now: Date) -> String {
        if journey.startDate <= now {
            return String(localized: "planned-trip.relative-start.now", defaultValue: "now", comment: "Planned trip relative start label when the journey has already begun.")
        }
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: journey.startDate)).day ?? 0
        if days < 1 {
            return journey.startDate.formatted(.relative(presentation: .named, unitsStyle: .wide))
        }
        return days == 1
            ? String(localized: "planned-trip.starts-in-days.one", defaultValue: "in \(days, format: .number.grouping(.never)) day", comment: "Upcoming trip countdown chip for a trip starting tomorrow.")
            : String(localized: "planned-trip.starts-in-days.other", defaultValue: "in \(days, format: .number.grouping(.never)) days", comment: "Upcoming trip countdown chip, e.g. in 36 days.")
    }
}
