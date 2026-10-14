import SwiftUI
import SwiftData
import WidgetKit

struct CurrentTripEntry: TimelineEntry {
    let date: Date
    let destinationSummary: String
    let countryFlags: String
    let dayCount: Int
    let isOngoing: Bool
    let dateRange: String
    let isEmpty: Bool
    /// A required read failed: the sample renders redacted rather than as the
    /// empty state or a finished trip while the user may be traveling.
    var isRedacted = false
    /// An active temporary home the user is at, not a trip: the day column
    /// reads "temporary home" where an ongoing trip reads "ongoing".
    var isTemporaryHome = false

    static var unavailable: CurrentTripEntry {
        var entry = sample
        entry.isRedacted = true
        return entry
    }

    static var empty: CurrentTripEntry {
        CurrentTripEntry(
            date: .now,
            destinationSummary: "",
            countryFlags: "",
            dayCount: 0,
            isOngoing: false,
            dateRange: "",
            isEmpty: true
        )
    }

    static var sample: CurrentTripEntry {
        let locale = SharedModelContainer.appLocale
        let start = Calendar.current.date(from: DateComponents(year: 2026, month: 5, day: 1))!
        let startText = start.formatted(
            Date.FormatStyle(locale: locale).month(.wide).day()
        )
        return CurrentTripEntry(
            date: .now,
            destinationSummary: "London, Oxford",
            countryFlags: "\u{1F1EC}\u{1F1E7}",
            dayCount: 5,
            isOngoing: true,
            dateRange: SharedModelContainer.localizedFormat(
                "widget.current-trip.date-range.present",
                defaultValue: "%@ - present",
                arguments: [startText]
            ),
            isEmpty: false
        )
    }
}

struct CurrentTripProvider: TimelineProvider {

    // Computed, not stored: a stored nil would never retry (see
    // `SharedModelContainer.container`).
    var modelContainer: ModelContainer? { SharedModelContainer.container }

    func placeholder(in context: Context) -> CurrentTripEntry {
        .sample
    }

    func getSnapshot(in context: Context, completion: @escaping (CurrentTripEntry) -> Void) {
        if context.isPreview {
            completion(.sample)
            return
        }
        completion(fetchEntry().entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CurrentTripEntry>) -> Void) {
        let fetched = fetchEntry()
        guard !fetched.retrySoon else {
            completion(Timeline(entries: [fetched.entry], policy: .after(SharedModelContainer.retryDate)))
            return
        }
        let entry = fetched.entry
        // Day-granularity value: reload at the next local midnight so the
        // "Day N" counter flips at the boundary, not on a drifting 6 h cadence.
        // A temporary home counts its days in its stored zone and an ongoing
        // trip in its last stay's, so that zone's midnight reloads it too.
        let nextUpdate = fetched.dayBoundary
            ?? SharedModelContainer.nextDayBoundaryRefresh(after: entry.date)
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }

    /// One container capture per attempt, shared by snapshots and timelines.
    /// No store, the empty fallback (see `SharedModelContainer.containerIsFallback`)
    /// or a failed required read: the redacted sample and a short retry. It
    /// is never the empty state or the last completed trip.
    private func fetchEntry() -> (entry: CurrentTripEntry, retrySoon: Bool, dayBoundary: Date?) {
        guard let modelContainer, !SharedModelContainer.containerIsFallback else {
            return (.unavailable, true, nil)
        }
        let context = ModelContext(modelContainer)
        let languageTag = SharedModelContainer.appLanguageTag
        let locale = SharedModelContainer.appLocale
        let monthDayStyle = Date.FormatStyle(locale: locale).month().day()
        let now = Date.now

        let found: Trip.WidgetSnapshot?
        do {
            found = try Trip.widgetSnapshot(in: context, now: now, languageTag: languageTag)
        } catch {
            SharedModelContainer.logReadFailure("CurrentTripWidget", error)
            return (.unavailable, true, nil)
        }
        guard let trip = found else { return (.empty, false, nil) }

        if trip.isOngoing {
            return (CurrentTripEntry(
                date: now,
                destinationSummary: trip.title ?? SharedModelContainer.localizedString(
                    "widget.current-trip.destination.fallback",
                    defaultValue: "Traveling",
                    languageTag: languageTag
                ),
                countryFlags: trip.countryFlags,
                dayCount: trip.dayCount,
                isOngoing: true,
                dateRange: SharedModelContainer.localizedFormat(
                    "widget.current-trip.date-range.present",
                    defaultValue: "%@ - present",
                    // A temporary home's start day is read in its stored zone.
                    arguments: [trip.startDayText(locale: locale)],
                    languageTag: languageTag
                ),
                isEmpty: false,
                isTemporaryHome: trip.isTemporaryHome
            ), false, trip.nextDayBoundary(after: now))
        }

        let range: String
        if let end = trip.endDate {
            range = (trip.startDate..<end).formatted(
                Date.IntervalFormatStyle(locale: locale).month().day()
            )
        } else {
            range = trip.startDate.formatted(monthDayStyle)
        }
        return (CurrentTripEntry(
            date: now,
            destinationSummary: trip.title ?? "",
            countryFlags: trip.countryFlags,
            dayCount: trip.dayCount,
            isOngoing: false,
            dateRange: range,
            isEmpty: false
        ), false, nil)
    }
}

struct CurrentTripWidgetView: View {

    let entry: CurrentTripEntry


    var body: some View {
        if entry.isEmpty {
            emptyView
        } else {
            tripView
                .redacted(reason: entry.isRedacted ? .placeholder : [])
        }
    }

    @ViewBuilder
    private var tripView: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                if !entry.countryFlags.isEmpty {
                    Text(entry.countryFlags)
                        .font(.title)
                }
                Text(entry.destinationSummary)
                    .font(.headline)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text(entry.dateRange)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 6) {
                Text(verbatim: SharedModelContainer.formatInteger(entry.dayCount))
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .widgetAccentable()
                Text(entry.dayCount == 1
                     ? SharedModelContainer.localizedString(
                        "widget.current-trip.day.one", defaultValue: "day")
                     : SharedModelContainer.localizedString(
                        "widget.current-trip.day.other", defaultValue: "days"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if entry.isTemporaryHome {
                    Text(SharedModelContainer.localizedString(
                        "widget.current-trip.temporary-home", defaultValue: "temporary home"))
                        .font(.caption2)
                        .foregroundStyle(.tint)
                } else if entry.isOngoing {
                    Text(SharedModelContainer.localizedString(
                        "ongoing", defaultValue: "ongoing"))
                        .font(.caption2)
                        .foregroundStyle(.tint)
                }
            }
        }
        .padding()
    }

    @ViewBuilder
    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "airplane")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .widgetAccentable()
            Text(SharedModelContainer.localizedString(
                "No trips yet", defaultValue: "No trips yet"))
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(SharedModelContainer.localizedString(
                "Start exploring to see your trips here",
                defaultValue: "Start exploring to see your trips here"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

struct CurrentTripWidget: Widget {
    let kind = "CurrentTripWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CurrentTripProvider()) { entry in
            CurrentTripWidgetView(entry: entry)
                .widgetURL(URL(string: "travellog://trips"))
                .containerBackground(.fill.tertiary, for: .widget)
                .environment(\.locale, SharedModelContainer.appLocale)
        }
        .configurationDisplayName("Current Trip")
        .description("Your ongoing or most recent trip at a glance.")
        .supportedFamilies([.systemMedium])
    }
}
