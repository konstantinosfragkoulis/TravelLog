//
//  TripSnippetViews.swift
//  TravelLog
//
//  Inline result cards for the App Intents surface — shown by Siri /
//  Spotlight / Shortcuts alongside the spoken dialog, so results render
//  without deep-linking into the app.
//
//  Snippets are archived and rendered out-of-process: keep them to plain
//  SwiftUI over the Sendable values passed in — no `@Query`, no
//  environment objects, no model types.
//

import SwiftUI

// MARK: - Trip list (SearchTripsIntent, WhereWasIIntent chaining)

struct TripListSnippetView: View {
    let trips: [TripEntity]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if trips.isEmpty {
                Text("No matching trips")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(trips.prefix(3), id: \.id) { trip in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(trip.title)
                                .font(.headline)
                                .lineLimit(1)
                            Text(trip.dateRangeText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text(trip.flags)
                    }
                }
                if trips.count > 3 {
                    let remaining = trips.count - 3
                    Text(remaining == 1
                        ? String(
                            localized: "app-intent.trip-snippet.more.one",
                            defaultValue: "and \(remaining, format: .number.grouping(.never)) more",
                            comment: "Trip snippet footer when one additional result is hidden."
                        )
                        : String(
                            localized: "app-intent.trip-snippet.more.other",
                            defaultValue: "and \(remaining, format: .number.grouping(.never)) more",
                            comment: "Trip snippet footer showing the number of additional hidden results."
                        )
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }
}

// MARK: - Stats card (TravelStatsIntent)

nonisolated struct SnippetStat: Identifiable {
    let label: String
    let value: String
    var id: String { label }
}

struct TravelStatsSnippetView: View {
    /// "All time" or a year like "2025".
    let heading: String
    let stats: [SnippetStat]

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(heading)
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(stats) { stat in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stat.value)
                            .font(.title2.bold())
                            .monospacedDigit()
                        Text(stat.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
    }
}

// MARK: - Where-was-I card (WhereWasIIntent)

struct WhereWasISnippetView: View {
    let dayText: String
    let visits: [DayVisit]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(dayText)
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
            if visits.isEmpty {
                Text("No location data")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(visits.prefix(4).enumerated()), id: \.offset) { _, visit in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(placeLine(for: visit))
                                .font(.headline)
                                .lineLimit(1)
                            if let tripName = visit.tripName {
                                Text(tripName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        if let flag = visit.flag {
                            Text(flag)
                        }
                    }
                }
                if visits.count > 4 {
                    let remaining = visits.count - 4
                    Text(String(
                        localized: "app-intent.where-was-i.snippet.additional-places",
                        defaultValue: "Additional places: \(remaining)",
                        comment: "Number of recorded places beyond the four visible Where Was I snippet rows."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }

    private func placeLine(for visit: DayVisit) -> String {
        switch visit.category {
        case .home, .routine:
            if visit.isTemporaryHome {
                if let place = visit.place {
                    return String(
                        localized: "app-intent.where-was-i.snippet.temporary-home-place",
                        defaultValue: "Temporary Home · \(place)",
                        comment: "Where Was I snippet label for a stay at the user's temporary home, followed by its place."
                    )
                }
                return String(localized: "app-intent.where-was-i.snippet.temporary-home", defaultValue: "Temporary Home", comment: "Where Was I snippet label for a stay at the user's temporary home.")
            }
            if let place = visit.place {
                return String(
                    localized: "app-intent.where-was-i.snippet.home-place",
                    defaultValue: "Home · \(place)",
                    comment: "Where Was I snippet label for a home or routine place."
                )
            }
            return String(localized: "app-intent.where-was-i.snippet.home", defaultValue: "Home", comment: "Where Was I snippet label for a home stay.")
        case .transit:
            if let place = visit.place {
                return String(
                    localized: "app-intent.where-was-i.snippet.transit-place",
                    defaultValue: "In transit · \(place)",
                    comment: "Where Was I snippet label for a transit place."
                )
            }
            return String(localized: "app-intent.where-was-i.snippet.transit", defaultValue: "In transit", comment: "Where Was I snippet label for a transit stay.")
        default:
            return visit.place ?? visit.countryName ?? String(
                localized: "app-intent.where-was-i.snippet.unknown",
                defaultValue: "Unknown",
                comment: "Where Was I snippet fallback when the place is unknown."
            )
        }
    }
}
