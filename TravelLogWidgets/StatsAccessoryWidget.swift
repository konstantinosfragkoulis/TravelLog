import SwiftUI
import SwiftData
import WidgetKit

struct StatsAccessoryEntry: TimelineEntry {
    let date: Date
    let countryCount: Int
    /// A required read failed: the placeholder renders redacted rather than
    /// as the remembered countries alone.
    var isRedacted = false

    static var unavailable: StatsAccessoryEntry {
        StatsAccessoryEntry(date: .now, countryCount: 12, isRedacted: true)
    }
}

struct StatsAccessoryProvider: TimelineProvider {

    // Computed, not stored: a stored nil would never retry (see
    // `SharedModelContainer.container`).
    var modelContainer: ModelContainer? { SharedModelContainer.container }

    func placeholder(in context: Context) -> StatsAccessoryEntry {
        StatsAccessoryEntry(date: .now, countryCount: 12)
    }

    func getSnapshot(in context: Context, completion: @escaping (StatsAccessoryEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        completion(fetchEntry().entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatsAccessoryEntry>) -> Void) {
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
    private func fetchEntry() -> (entry: StatsAccessoryEntry, retrySoon: Bool) {
        guard let modelContainer, !SharedModelContainer.containerIsFallback else {
            return (.unavailable, true)
        }
        let countryCodes: Set<String>
        do {
            countryCodes = try Stay.widgetVisitedCountryCodes(in: modelContainer)
        } catch {
            SharedModelContainer.logReadFailure("StatsAccessoryWidget", error)
            return (.unavailable, true)
        }

        // `passportData.countries` is tracked-only; the caller owes the
        // remembered union (see `RememberedCountriesMirror`).
        let remembered = RememberedCountriesMirror.codes(
            appGroupIdentifier: SharedModelContainer.appGroupIdentifier
        )
        return (StatsAccessoryEntry(date: .now, countryCount: countryCodes.union(remembered).count), false)
    }
}

struct StatsAccessoryWidgetView: View {

    let entry: StatsAccessoryEntry

    @Environment(\.widgetFamily) var family

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                circularView
            case .accessoryInline:
                inlineView
            default:
                circularView
            }
        }
        .redacted(reason: entry.isRedacted ? .placeholder : [])
    }

    @ViewBuilder
    private var circularView: some View {
        VStack(spacing: 2) {
            Image(systemName: "globe")
                .font(.caption)
                .widgetAccentable()
            Text(verbatim: SharedModelContainer.formatInteger(entry.countryCount))
                .font(.title2.bold().monospacedDigit())
        }
        // The globe and bare number read as the inline phrase.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(countriesVisitedText)
    }

    @ViewBuilder
    private var inlineView: some View {
        Label(countriesVisitedText, systemImage: "globe")
    }

    private var countriesVisitedText: String {
        entry.countryCount == 1
            ? SharedModelContainer.localizedFormat(
                "widget.travel-counter.countries.one",
                defaultValue: "%@ country visited",
                arguments: [SharedModelContainer.formatInteger(entry.countryCount)])
            : SharedModelContainer.localizedFormat(
                "widget.travel-counter.countries.other",
                defaultValue: "%@ countries visited",
                arguments: [SharedModelContainer.formatInteger(entry.countryCount)])
    }
}

struct StatsAccessoryWidget: Widget {
    let kind = "StatsAccessoryWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StatsAccessoryProvider()) { entry in
            StatsAccessoryWidgetView(entry: entry)
                .widgetURL(URL(string: "travellog://stats"))
                .containerBackground(.fill.tertiary, for: .widget)
                .environment(\.locale, SharedModelContainer.appLocale)
        }
        .configurationDisplayName("Travel Counter")
        .description("Countries visited on your lock screen.")
        .supportedFamilies([.accessoryCircular, .accessoryInline])
    }
}
