//
//  FlightLogSummaryView.swift
//  TravelLog
//
//  A compact summary of the same journeys shown by the Flight Log's
//  period and search. This counts journeys, not assumed flight segments.
//

import SwiftUI

struct FlightLogSummaryView: View {
    let summary: FlightLogProjection.Summary

    private var journeyLabel: String {
        String(localized: "flight-log.summary.journeys", defaultValue: "Journeys", comment: "Flight Log summary count of recorded air journeys, which may have unrecorded connections.")
    }

    private var routeLabel: String {
        String(localized: "flight-log.summary.routes", defaultValue: "Routes", comment: "Flight Log summary count of distinct recorded endpoint routes.")
    }

    private var distanceLabel: String {
        String(localized: "flight-log.summary.distance", defaultValue: "Approx. distance", comment: "Flight Log summary distance label; distances are estimates through recorded endpoints and connections.")
    }

    private var distanceValue: String {
        guard summary.distanceJourneyCount > 0 else {
            return String(localized: "flight-log.summary.distance.unavailable", defaultValue: "Unavailable", comment: "Flight Log distance value when no selected journey has supported route geometry.")
        }
        return UnitsFormatter.formatDistance(kilometers: summary.estimatedKm)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) {
                    metric(journeyLabel, value: summary.journeyCount.formatted(.number))
                    metric(routeLabel, value: summary.routeCount.formatted(.number))
                    metric(distanceLabel, value: distanceValue)
                }
                VStack(alignment: .leading, spacing: 8) {
                    summaryRow(journeyLabel, value: summary.journeyCount.formatted(.number))
                    summaryRow(routeLabel, value: summary.routeCount.formatted(.number))
                    summaryRow(distanceLabel, value: distanceValue)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let route = summary.mostRecordedRoute, summary.mostRecordedRouteCount > 1 {
                Text(String(localized: "flight-log.summary.most-recorded", defaultValue: "Most recorded: \(route) · \(summary.mostRecordedRouteCount, format: .number.grouping(.never)) journeys", comment: "Flight Log scoped most-recorded route, shown only for a route appearing more than once."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if summary.distanceJourneyCount < summary.journeyCount {
                Text(String(localized: "flight-log.summary.distance.coverage", defaultValue: "Journeys with distance available: \(summary.distanceJourneyCount, format: .number.grouping(.never)) of \(summary.journeyCount, format: .number.grouping(.never)).", comment: "Flight Log summary disclosure when not every selected journey has supported geometry for an approximate distance."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if summary.routeJourneyCount < summary.journeyCount {
                Text(String(localized: "flight-log.summary.routes.coverage", defaultValue: "Journeys with identifiable routes: \(summary.routeJourneyCount, format: .number.grouping(.never)) of \(summary.journeyCount, format: .number.grouping(.never)).", comment: "Flight Log disclosure when some selected journeys lack enough geographic information to count distinct routes reliably."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
    }

    private func metric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(AppTheme.stat(.headline, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }

    private func summaryRow(_ label: String, value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .font(AppTheme.stat(.subheadline, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .font(.subheadline)
    }
}
