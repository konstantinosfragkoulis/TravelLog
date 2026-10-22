//
//  UpcomingTripWidget.swift
//  TravelLogWidgets
//
//  Countdown to the next calendar-detected journey.
//  Reads `PlannedTrip` rows from the shared read-only store and
//  chains them with the SAME `PlannedTripChainer` the app's Trips-list card
//  uses (the file is opted into this target via pbxproj
//  membershipExceptions), so the widget, Siri, and the app always name the
//  same next journey. The store reads are shared with the Next Trip intent
//  (`PlannedTripChainer.storeInputs`).
//

import SwiftUI
import SwiftData
import WidgetKit

struct UpcomingTripEntry: TimelineEntry {
    let date: Date
    let journeyName: String
    let dateRange: String
    let daysUntilStart: Int
    let isOngoing: Bool
    let isEmpty: Bool
    let journeyStart: Date?
    /// A required read failed: the sample renders redacted rather than as
    /// "No upcoming trips" or a journey the app would not name.
    var isRedacted = false

    static var unavailable: UpcomingTripEntry {
        var entry = sample
        entry.isRedacted = true
        return entry
    }

    static var empty: UpcomingTripEntry {
        UpcomingTripEntry(date: .now, journeyName: "", dateRange: "", daysUntilStart: 0, isOngoing: false, isEmpty: true, journeyStart: nil)
    }

    static var sample: UpcomingTripEntry {
        let locale = SharedModelContainer.appLocale
        let calendar = Calendar.current
        let start = calendar.date(from: DateComponents(year: 2027, month: 5, day: 23))!
        let end = calendar.date(from: DateComponents(year: 2027, month: 5, day: 31))!
        let range = DateRangeText.format(
            start..<end, Date.IntervalFormatStyle(locale: locale).day().month(.abbreviated)
        )
        return UpcomingTripEntry(date: .now, journeyName: "Cephalonia → Ios", dateRange: range, daysUntilStart: 12, isOngoing: false, isEmpty: false, journeyStart: nil)
    }
}

struct UpcomingTripProvider: TimelineProvider {

    // Computed, not stored: a stored nil would never retry (see
    // `SharedModelContainer.container`).
    var modelContainer: ModelContainer? { SharedModelContainer.container }

    func placeholder(in context: Context) -> UpcomingTripEntry {
        .sample
    }

    func getSnapshot(in context: Context, completion: @escaping (UpcomingTripEntry) -> Void) {
        if context.isPreview {
            completion(.sample)
            return
        }
        completion(fetchEntry().entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UpcomingTripEntry>) -> Void) {
        // Unavailable (no store, fallback shell, or a failed read): only that
        // entry, on the short retry, with no departure transition.
        let fetched = fetchEntry()
        guard !fetched.retrySoon else {
            completion(Timeline(entries: [fetched.entry], policy: .after(SharedModelContainer.retryDate)))
            return
        }
        let entry = fetched.entry
        // Refresh at the next local midnight — the countdown only changes at
        // the day boundary, and the app's own scans reload timelines when
        // detections change. A leg that expires first (a timed leg ending at
        // noon) can change the journey named, so a second after it too.
        var nextUpdate = SharedModelContainer.nextDayBoundaryRefresh(after: entry.date)
        if let expiry = fetched.nextLegExpiry {
            nextUpdate = min(nextUpdate, expiry.addingTimeInterval(1))
        }
        var entries = [entry]
        // A timed first leg starts mid-day: add an "On trip" entry at
        // departure so the widget doesn't wait for the midnight reload.
        if !entry.isEmpty, !entry.isOngoing, let journeyStart = entry.journeyStart,
           let transition = PlannedTripChainer.startTransitionDate(
               journeyStart: journeyStart, now: entry.date, refresh: nextUpdate) {
            entries.append(UpcomingTripEntry(
                date: transition,
                journeyName: entry.journeyName,
                dateRange: entry.dateRange,
                daysUntilStart: 0,
                isOngoing: true,
                isEmpty: false,
                journeyStart: journeyStart
            ))
        }
        completion(Timeline(entries: entries, policy: .after(nextUpdate)))
    }

    /// One container capture per attempt, shared by snapshots and timelines. No
    /// store, or the empty fallback: unavailable on a short retry, not 12 h (see
    /// `SharedModelContainer.containerIsFallback`). A failed planned-trip, Home
    /// or ongoing-trip read is unavailable too: each changes which journey is
    /// named.
    private func fetchEntry() -> (entry: UpcomingTripEntry, retrySoon: Bool, nextLegExpiry: Date?) {
        guard let modelContainer, !SharedModelContainer.containerIsFallback else {
            return (.unavailable, true, nil)
        }
        let context = ModelContext(modelContainer)
        let now = Date.now
        let locale = SharedModelContainer.appLocale

        // Same reads as the Next Trip intent (`storeInputs`), chained by the
        // same `PlannedTripChainer` as the app card.
        let inputs: PlannedTripChainer.StoreInputs
        do {
            inputs = try PlannedTripChainer.storeInputs(in: context, now: now)
        } catch {
            SharedModelContainer.logReadFailure("UpcomingTripWidget", error)
            return (.unavailable, true, nil)
        }
        guard let journey = PlannedTripChainer.nextJourney(
            from: inputs.legs,
            homeNames: inputs.homeNames,
            now: now,
            ongoingTripStartDates: inputs.ongoingTripStartDates
        ) else { return (.empty, false, inputs.nextLegExpiry) }

        let days = Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: now),
            to: Calendar.current.startOfDay(for: journey.startDate)
        ).day ?? 0
        let range = DateRangeText.format(
            journey.displayDateRange(), Date.IntervalFormatStyle(locale: locale).day().month(.abbreviated)
        )
        return (UpcomingTripEntry(
            date: now,
            journeyName: journey.displayName(locale: locale),
            dateRange: range,
            daysUntilStart: max(0, days),
            isOngoing: journey.startDate <= now,
            isEmpty: false,
            journeyStart: journey.startDate
        ), false, inputs.nextLegExpiry)
    }
}

struct UpcomingTripWidgetView: View {
    var entry: UpcomingTripEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if entry.isEmpty {
            VStack(spacing: 4) {
                Image(systemName: "calendar.badge.clock")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .widgetAccentable()
                Text(SharedModelContainer.localizedString(
                    "No upcoming trips", defaultValue: "No upcoming trips"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if entry.isOngoing && family != .accessoryRectangular {
                    // Saffron marks only what is happening now.
                    WidgetActivePill(text: ongoingText)
                } else {
                    Label(entry.isOngoing ? ongoingText : countdownText, systemImage: "calendar.badge.clock")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tint)
                }
                Spacer(minLength: 0)
                Text(entry.journeyName)
                    .font(family == .accessoryRectangular ? .headline : .title3.bold())
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Text(entry.dateRange)
                    .font(family == .accessoryRectangular ? .caption2 : .caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .redacted(reason: entry.isRedacted ? .placeholder : [])
        }
    }

    private var ongoingText: String {
        SharedModelContainer.localizedString(
            "widget.upcoming-trip.status.ongoing", defaultValue: "On trip")
    }

    private var countdownText: String {
        entry.daysUntilStart == 1
            ? SharedModelContainer.localizedFormat(
                "widget.upcoming-trip.countdown.one",
                defaultValue: "In %@ day",
                arguments: [SharedModelContainer.formatInteger(entry.daysUntilStart)])
            : SharedModelContainer.localizedFormat(
                "widget.upcoming-trip.countdown.other",
                defaultValue: "In %@ days",
                arguments: [SharedModelContainer.formatInteger(entry.daysUntilStart)])
    }
}

struct UpcomingTripWidget: Widget {
    let kind: String = "UpcomingTripWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UpcomingTripProvider()) { entry in
            UpcomingTripWidgetView(entry: entry)
                .containerBackground(WidgetTheme.card, for: .widget)
                .environment(\.locale, SharedModelContainer.appLocale)
        }
        .configurationDisplayName("Upcoming Trip")
        .description("Countdown to the next trip detected from your calendar.")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
    }
}
