import SwiftUI
import SwiftData
import WidgetKit

struct TravelStatsEntry: TimelineEntry {
    let date: Date
    let countryCount: Int
    let cityCount: Int
    let tripCount: Int
    let hexCount: Int
    /// A required read failed: the placeholder renders redacted rather than
    /// as counts that look real.
    var isRedacted = false

    static var unavailable: TravelStatsEntry {
        TravelStatsEntry(date: .now, countryCount: 12, cityCount: 45, tripCount: 8, hexCount: 234,
                         isRedacted: true)
    }
}

struct TravelStatsProvider: TimelineProvider {

    // Computed, not stored: a stored nil would never retry (see
    // `SharedModelContainer.container`).
    var modelContainer: ModelContainer? { SharedModelContainer.container }

    func placeholder(in context: Context) -> TravelStatsEntry {
        TravelStatsEntry(date: .now, countryCount: 12, cityCount: 45, tripCount: 8, hexCount: 234)
    }

    func getSnapshot(in context: Context, completion: @escaping (TravelStatsEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        completion(fetchEntry().entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TravelStatsEntry>) -> Void) {
        let fetched = fetchEntry()
        guard !fetched.retrySoon else {
            completion(Timeline(entries: [fetched.entry], policy: .after(SharedModelContainer.retryDate)))
            return
        }
        let entry = fetched.entry
        let nextUpdate = Calendar.current.date(byAdding: .hour, value: 6, to: entry.date) ?? entry.date.addingTimeInterval(6 * 3600)
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }

    /// One container capture per attempt, shared by snapshots and timelines.
    /// No store, the empty fallback (see `SharedModelContainer.containerIsFallback`)
    /// or a failed required read: the redacted placeholder and a short retry.
    /// None of them is an empty history.
    private func fetchEntry() -> (entry: TravelStatsEntry, retrySoon: Bool) {
        guard let modelContainer, !SharedModelContainer.containerIsFallback else {
            return (.unavailable, true)
        }
        let stats: Stay.WidgetTravelStats
        do {
            stats = try Stay.widgetTravelStats(in: modelContainer)
        } catch {
            SharedModelContainer.logReadFailure("TravelStatsWidget", error)
            return (.unavailable, true)
        }

        // `passportData.countries` is tracked-only; the caller owes the
        // remembered union (see `RememberedCountriesMirror`).
        let remembered = RememberedCountriesMirror.codes(
            appGroupIdentifier: SharedModelContainer.appGroupIdentifier
        )

        return (TravelStatsEntry(
            date: .now,
            countryCount: stats.countryCodes.union(remembered).count,
            cityCount: stats.cityCount,
            tripCount: stats.tripCount,
            hexCount: stats.hexCount
        ), false)
    }
}

struct TravelStatsWidgetView: View {

    let entry: TravelStatsEntry


    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                statCell(icon: "flag.fill", value: entry.countryCount, label: SharedModelContainer.localizedString("widget.travel-stats.countries", defaultValue: "Countries"))
                statCell(icon: "building.2.fill", value: entry.cityCount, label: SharedModelContainer.localizedString("widget.travel-stats.cities", defaultValue: "Cities"))
            }
            HStack(spacing: 12) {
                statCell(icon: "airplane", value: entry.tripCount, label: SharedModelContainer.localizedString("widget.travel-stats.trips", defaultValue: "Trips"))
                statCell(icon: "hexagon.fill", value: entry.hexCount, label: SharedModelContainer.localizedString("widget.travel-stats.hexes", defaultValue: "Hexes"))
            }
        }
        .padding(12)
        .redacted(reason: entry.isRedacted ? .placeholder : [])
    }

    @ViewBuilder
    private func statCell(icon: String, value: Int, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .widgetAccentable()
                .accessibilityHidden(true)
            Text(verbatim: SharedModelContainer.formatInteger(value))
                .font(.title3.bold().monospacedDigit())
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        // One element per stat: "12 Countries".
        .accessibilityElement(children: .combine)
    }
}

struct TravelStatsWidget: Widget {
    let kind = "TravelStatsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TravelStatsProvider()) { entry in
            TravelStatsWidgetView(entry: entry)
                .widgetURL(URL(string: "travellog://stats"))
                .containerBackground(.fill.tertiary, for: .widget)
                .environment(\.locale, SharedModelContainer.appLocale)
        }
        .configurationDisplayName("Travel Stats")
        .description("Countries, cities, trips, and hexes at a glance.")
        .supportedFamilies([.systemSmall])
    }
}
