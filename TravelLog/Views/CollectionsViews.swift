//
//  CollectionsViews.swift
//  TravelLog
//
//  The Stats "Collections" surface: a card of rows pushing the
//  three collection lists — Airports visited, the inferred Flight Log, and
//  the Places gazetteer. All three render a precomputed
//  `CollectionsAggregator.Collections` value handed down from `StatsView`'s
//  cached aggregates — no fetching, no recompute on push.
//

import SwiftUI
import SwiftData
import os.log

private let collectionsLogger = Logger(
    subsystem: "com.travellog.app", category: "CollectionsViews")

// MARK: - Stats-tab section

struct CollectionsSectionView: View {
    let collections: CollectionsAggregator.Collections

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Collections")
                .font(.headline)

            NavigationLink {
                PlacesListView(places: collections.places)
            } label: {
                collectionRow(
                    icon: "building.2.fill", tint: .indigo,
                    title: String(localized: "collections.row.places", defaultValue: "Places", comment: "Collections card row title for the places collection."),
                    count: collections.places.count
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                AirportsListView(airports: collections.airports)
            } label: {
                collectionRow(
                    icon: "airplane.circle.fill", tint: .teal,
                    title: String(localized: "collections.row.airports", defaultValue: "Airports", comment: "Collections card row title for the airports collection."),
                    count: collections.airports.count
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                FlightLogView(
                    flights: collections.flights,
                    stats: collections.flightStats,
                    possibleFlights: collections.possibleFlights
                )
            } label: {
                collectionRow(
                    icon: "airplane.departure", tint: .orange,
                    title: String(localized: "collections.row.flights", defaultValue: "Flights", comment: "Collections card row title for the flights collection."),
                    count: collections.flights.count,
                    detail: collections.possibleFlights.isEmpty
                        ? nil
                        : (collections.possibleFlights.count == 1
                           ? String(localized: "collections.flights.to-review.one", defaultValue: "\(collections.possibleFlights.count, format: .number.grouping(.never)) to review", comment: "Collections flight row detail when one possible flight needs review.")
                           : String(localized: "collections.flights.to-review.other", defaultValue: "\(collections.possibleFlights.count, format: .number.grouping(.never)) to review", comment: "Collections flight row detail when multiple possible flights need review."))
                )
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
    }

    @ViewBuilder
    private func collectionRow(icon: String, tint: Color, title: String, count: Int, detail: String? = nil) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("\(count)")
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(title)
                    .foregroundStyle(.primary)
            }
        }
        .font(.subheadline)
        .contentShape(.rect)
    }
}

// MARK: - Airports

struct AirportsListView: View {
    let airports: [CollectionsAggregator.AirportEntry]
    @State private var searchText = ""
    @State private var indexMemo = SearchMemo<
        ListSearchKey<CollectionsAggregator.AirportEntry>,
        ListSearchIndex<CollectionsAggregator.AirportEntry>>()

    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var filtered: [CollectionsAggregator.AirportEntry] {
        guard !query.isEmpty else { return airports }
        let languageTag = AppLanguagePreference.currentTag()
        let index = indexMemo.value(for: ListSearchKey(entries: airports, languageTag: languageTag)) {
            Self.searchIndex(airports, languageTag: languageTag)
        }
        return Self.matchingAirports(in: index, query: searchText)
    }

    var body: some View {
        let shown = filtered
        let flownCount = shown.count(where: \.flownThrough)
        List {
            if airports.isEmpty {
                ContentUnavailableView(
                    "No Airports Yet",
                    systemImage: "airplane.circle",
                    description: Text("Airports appear here after a stay near one: a flight, a layover, or a pickup.")
                )
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                // While filtering, the header counts the rows shown.
                Section {
                    ForEach(shown) { airport in
                        airportRow(airport)
                    }
                } header: {
                    Text(shown.count == 1
                         ? String(localized: "collections.airports.summary.one", defaultValue: "\(shown.count, format: .number.grouping(.never)) airport · \(flownCount, format: .number.grouping(.never)) flown through", comment: "Airports collection header for one airport, including how many were flown through.")
                         : String(localized: "collections.airports.summary.other", defaultValue: "\(shown.count, format: .number.grouping(.never)) airports · \(flownCount, format: .number.grouping(.never)) flown through", comment: "Airports collection header for multiple airports, including how many were flown through."))
                }
            }
        }
        .navigationTitle("Airports")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Code, name, or city")
    }

    @ViewBuilder
    private func airportRow(_ airport: CollectionsAggregator.AirportEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(airport.isoCountryCode.flatMap(flagEmoji(for:)) ?? "🏳️")
                Text(airport.code)
                    .font(.subheadline.weight(.semibold))
                    .monospaced()
                if airport.flownThrough {
                    Image(systemName: "airplane")
                        .font(.caption2)
                        .foregroundStyle(.teal)
                        .accessibilityLabel("Flown through")
                }
                Spacer()
                Text(airport.stayCount == 1
                     ? String(localized: "collections.airport.visits.one", defaultValue: "\(airport.stayCount, format: .number.grouping(.never)) visit", comment: "Airport row count for one visit.")
                     : String(localized: "collections.airport.visits.other", defaultValue: "\(airport.stayCount, format: .number.grouping(.never)) visits", comment: "Airport row count for multiple visits."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let name = airport.name {
                Text(name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text("First visit \(airport.firstVisit, format: .dateTime.month(.abbreviated).year())")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

extension AirportsListView {
    nonisolated static func matchingAirports(
        _ airports: [CollectionsAggregator.AirportEntry],
        query: String,
        languageTag: String = AppLanguagePreference.currentTag()
    ) -> [CollectionsAggregator.AirportEntry] {
        matchingAirports(in: searchIndex(airports, languageTag: languageTag), query: query)
    }

    /// Engine matches in list order; a query that is exactly an airport's
    /// IATA code (any case) always lists that airport, first.
    nonisolated static func matchingAirports(
        in index: ListSearchIndex<CollectionsAggregator.AirportEntry>,
        query: String
    ) -> [CollectionsAggregator.AirportEntry] {
        var result = index.matching(query)
        let code = query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if code.count == 3, let exact = index.entries.first(where: { $0.code.uppercased() == code }) {
            result.removeAll { $0.id == exact.id }
            result.insert(exact, at: 0)
        }
        return result
    }

    /// Code, airport name and city as names; the ISO code's aliases as
    /// countries.
    nonisolated static func searchIndex(
        _ airports: [CollectionsAggregator.AirportEntry],
        languageTag: String
    ) -> ListSearchIndex<CollectionsAggregator.AirportEntry> {
        var aliasesByISO: [String: [String]] = [:]
        return ListSearchIndex(entries: airports, languageTag: languageTag) { airport in
            var countries: [String] = []
            var codes: Set<String> = []
            if let iso = airport.isoCountryCode?.uppercased(), !iso.isEmpty {
                let aliases = aliasesByISO[iso]
                    ?? TripSearch.countryAliases(for: [iso], languageTag: languageTag)
                aliasesByISO[iso] = aliases
                countries = aliases
                codes.insert(iso)
            }
            return ([airport.code] + [airport.name, airport.city].compactMap { $0 }, countries, codes)
        }
    }
}

// MARK: - Flight log

struct FlightLogView: View {
    let flights: [CollectionsAggregator.FlightRecord]
    let stats: CollectionsAggregator.FlightStats
    let possibleFlights: [CollectionsAggregator.PossibleFlight]

    /// Optimistic removal for candidates the user just confirmed or
    /// dismissed — the next aggregate recompute makes it authoritative
    /// (confirmed legs come back as real flights; dismissed ones are
    /// filtered by `FlightCandidateDismissals`).
    @State private var resolvedCandidateIDs: Set<UUID> = []
    @State private var saveFailed = false

    private var pendingCandidates: [CollectionsAggregator.PossibleFlight] {
        possibleFlights.filter { !resolvedCandidateIDs.contains($0.id) }
    }

    var body: some View {
        List {
            if flights.isEmpty && pendingCandidates.isEmpty {
                ContentUnavailableView(
                    "No Flights Detected",
                    systemImage: "airplane.departure",
                    description: Text("Flights are inferred from your movement between airports. They appear here once the pipeline spots one.")
                )
            } else {
                if !pendingCandidates.isEmpty {
                    Section {
                        ForEach(pendingCandidates) { candidate in
                            candidateRow(candidate)
                        }
                    } header: {
                        Text("Possible Flights")
                    } footer: {
                        Text("Legs that look like flights from your movement patterns. Confirming adds one to your log; dismissing hides it permanently.")
                    }
                }
                if !flights.isEmpty {
                    totalsSection
                    Section("Flights") {
                        ForEach(flights) { flight in
                            flightRow(flight)
                        }
                    }
                }
            }
        }
        .navigationTitle("Flight Log")
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            String(
                localized: "common.save-error.try-again",
                defaultValue: "Couldn't save. Try again",
                comment: "Shared alert title after a user-authoritative save fails."
            ),
            isPresented: $saveFailed
        ) {
            Button("OK", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var totalsSection: some View {
        Section {
                    statRow(String(localized: "collections.flight-stat.flights", defaultValue: "Flights", comment: "Flight Log total statistic label for flights."), value: "\(stats.totalFlights)")
                    statRow(String(localized: "collections.flight-stat.distance-flown", defaultValue: "Distance flown", comment: "Flight Log total statistic label for distance flown."), value: UnitsFormatter.formatDistance(kilometers: stats.totalKm))
                    statRow(String(localized: "collections.flight-stat.time-in-air", defaultValue: "Time in the air", comment: "Flight Log total statistic label for estimated time in the air."), value: "≈ \(formatHours(stats.totalEstimatedHours))")
                    if stats.totalKm > 0 {
                        statRow(String(localized: "collections.flight-stat.around-world", defaultValue: "Around the world", comment: "Flight Log statistic label comparing distance flown to trips around Earth."), value: String(localized: "collections.flight-stat.around-world.value", defaultValue: "\(stats.totalKm / 40_075, format: .number.precision(.fractionLength(1)))×", comment: "Flight Log value showing an equivalent number of trips around Earth."))
                    }
                    if stats.internationalCount > 0 {
                        statRow(String(localized: "collections.flight-stat.international", defaultValue: "International", comment: "Flight Log total statistic label for international flights."), value: "\(stats.internationalCount)")
                    }
                    if stats.overnightCount > 0 {
                        statRow(String(localized: "collections.flight-stat.overnight", defaultValue: "Overnight", comment: "Flight Log total statistic label for overnight flights."), value: "\(stats.overnightCount)")
                    }
                    if stats.timeZonesCrossedTotal > 0 {
                        statRow(String(localized: "collections.flight-stat.time-zones-crossed", defaultValue: "Time zones crossed", comment: "Flight Log total statistic label for time zones crossed."), value: "\(stats.timeZonesCrossedTotal)")
                    }
                    if let route = stats.mostFlownRouteLabel, stats.mostFlownRouteCount > 1 {
                        statRow(String(localized: "collections.flight-stat.most-flown-route", defaultValue: "Most flown route", comment: "Flight Log statistic label for the route flown most often."), value: "\(route) ×\(stats.mostFlownRouteCount)")
                    }
                    if let longest = stats.longestRouteLabel, stats.longestKm > 0 {
                        statRow(String(localized: "collections.flight-stat.longest-flight", defaultValue: "Longest flight", comment: "Flight Log statistic label for the longest flight."),
                                value: "\(longest) · \(UnitsFormatter.formatDistance(kilometers: stats.longestKm))")
                    }
                } header: {
                    Text("Totals")
                } footer: {
                    Text("Routes and durations are inferred from location data. Durations are estimates.")
                }

    }

    @ViewBuilder
    private func candidateRow(_ candidate: CollectionsAggregator.PossibleFlight) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(candidate.record.routeLabel)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(Self.flightDateText(candidate.record))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("\(UnitsFormatter.formatDistance(kilometers: candidate.record.distanceKm)) · \(candidate.evidence?.displayText ?? String(localized: "collections.flight-candidate.evidence.fallback", defaultValue: "Flight-shaped leg", comment: "Fallback evidence description for a possible flight.")) · \(formatGap(candidate.gapHours))")
                .font(.caption)
                .foregroundStyle(.secondary)
            // `.borderless` is the one button style List treats as plain
            // inline content — the bordered styles lose the geometry
            // negotiation with the row (stretched wide, then tall). Explicit
            // capsule labels give them
            // their shape instead, matching the kind-chip language.
            HStack(spacing: 10) {
                Button {
                    confirmCandidate(candidate)
                } label: {
                    Label("Confirm Flight", systemImage: "checkmark")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.tint, in: .capsule)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.borderless)

                Button {
                    dismissCandidate(candidate)
                } label: {
                    Label("Dismiss", systemImage: "xmark")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.quaternary, in: .capsule)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    /// Confirm = the user vouching for the leg: write the terminal
    /// `.flight` onto the arrival stay (gated like every store mutator —
    /// the thin-wrapper + @MainActor static worker pattern from
    /// `TripDetailView.saveRename`) and persist the computed distance. The
    /// tracker bump from the gate unit re-runs the Stats aggregate, which
    /// moves the leg into the real log.
    private func confirmCandidate(_ candidate: CollectionsAggregator.PossibleFlight) {
        resolvedCandidateIDs.insert(candidate.id)
        let targetID = candidate.id
        let distanceKm = candidate.record.distanceKm
        Task {
            let saved = await PipelineGate.shared.runReturning(touching: [.stay]) {
                await Self.applyConfirmedFlight(stayID: targetID, distanceKm: distanceKm)
            }
            if !saved {
                resolvedCandidateIDs.remove(targetID)
                saveFailed = true
            }
        }
    }

    /// Internal + context-injectable as a test seam (`FlightConfirmFlowTests`);
    /// the view always passes the app's main context.
    @MainActor
    @discardableResult
    static func applyConfirmedFlight(
        stayID: UUID,
        distanceKm: Double,
        modelContext: ModelContext? = nil
    ) -> Bool {
        let modelContext = modelContext ?? AppDelegate.modelContainer.mainContext
        guard preserveUnrelatedPendingEdits(in: modelContext) else { return false }
        let descriptor = FetchDescriptor<Stay>(
            predicate: #Predicate { $0.id == stayID }
        )
        // A failed read is not absence: only a successful
        // fetch that finds no row (deleted or wiped) is the safe no-op.
        let stay: Stay?
        do {
            #if DEBUG
            try confirmFetchFailure?()
            #endif
            stay = try modelContext.fetch(descriptor).first
        } catch {
            collectionsLogger.error("Flight confirmation fetch failed: \(error.localizedDescription)")
            return false
        }
        guard let stay else { return true }
        stay.transitFromPreviousRaw = TransitMode.flight.rawValue
        // Unconditional: the stored value on a
        // `.unknown` leg can be STALE — computed against a predecessor that
        // later imports displaced — which is exactly why candidate mining
        // ignores it (`preferStoredDistance: false`). The user just vouched
        // for the leg AS DISPLAYED; keeping a stale stored value here made
        // the log render a different distance than the queue showed.
        stay.distanceFromPreviousKm = distanceKm
        do {
            try modelContext.save()
            return true
        } catch {
            modelContext.rollback()
            collectionsLogger.error("Flight confirmation save failed: \(error.localizedDescription)")
            return false
        }
    }

    #if DEBUG
    @TaskLocal private static var confirmFetchFailure: (@MainActor () throws -> Void)?

    @discardableResult
    static func applyConfirmedFlightForTesting(
        stayID: UUID,
        distanceKm: Double,
        modelContext: ModelContext,
        beforeFetch: @escaping @MainActor () throws -> Void
    ) -> Bool {
        $confirmFetchFailure.withValue(beforeFetch) {
            applyConfirmedFlight(stayID: stayID, distanceKm: distanceKm, modelContext: modelContext)
        }
    }
    #endif

    private func dismissCandidate(_ candidate: CollectionsAggregator.PossibleFlight) {
        resolvedCandidateIDs.insert(candidate.id)
        FlightCandidateDismissals.dismiss(candidate.id)
        // Confirm refreshes Stats via its gate unit's `.stay` bump; dismiss
        // writes only UserDefaults, so without a bump the next aggregate
        // (built with the new dismissals set) never runs — the candidate
        // reappears and the "N to review" badge stays stale once the
        // view-local `resolvedCandidateIDs` state dies.
        StoreChangeTracker.shared.bump(.stay)
    }

    private func formatGap(_ hours: Double) -> String {
        let duration = Duration.seconds(hours * 60 * 60)
        if hours < 48 {
            let value = duration.formatted(.units(
                allowed: [.hours], width: .narrow, maximumUnitCount: 1,
                fractionalPart: .init(lengthLimits: 1...1, roundingRule: .toNearestOrAwayFromZero)
            ))
            return hours == 1
                ? String(localized: "collections.flight-gap.hours.one", defaultValue: "\(value) gap", comment: "Possible-flight gap lasting one hour.")
                : String(localized: "collections.flight-gap.hours.other", defaultValue: "\(value) gap", comment: "Possible-flight gap lasting multiple hours.")
        }
        let days = Int((hours / 24).rounded())
        let value = Duration.seconds(Double(days) * 24 * 60 * 60).formatted(.units(
            allowed: [.days], width: .narrow, maximumUnitCount: 1,
            fractionalPart: .hide(rounded: .toNearestOrAwayFromZero)
        ))
        return String(localized: "collections.flight-gap.days.other", defaultValue: "\(value) gap", comment: "Possible-flight gap lasting multiple days.")
    }

    /// Honest date display: location data only brackets a flight between
    /// the last fix at the origin and the first fix at the destination —
    /// for photo-era legs that window spans days, so a single date is
    /// wrong by up to the gap. Same-day windows render as one date; wider
    /// ones as a range.
    static func flightDateText(_ record: CollectionsAggregator.FlightRecord) -> String {
        guard let start = record.departureWindowStart,
              !Calendar.current.isDate(start, inSameDayAs: record.date) else {
            return record.date.formatted(.dateTime.day().month(.abbreviated).year())
        }
        return (start..<record.date).formatted(
            Date.IntervalFormatStyle(date: .abbreviated, time: .omitted)
        )
    }

    @ViewBuilder
    private func statRow(_ label: String, value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private func flightRow(_ flight: CollectionsAggregator.FlightRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(flight.routeLabel)
                    .font(.subheadline.weight(.semibold))
                if flight.isOvernight {
                    Image(systemName: "moon.fill")
                        .font(.caption2)
                        .foregroundStyle(.indigo)
                        .accessibilityLabel("Overnight flight")
                }
                Spacer()
                Text(Self.flightDateText(flight))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("\(UnitsFormatter.formatDistance(kilometers: flight.distanceKm)) · ≈ \(formatHours(flight.estimatedHours))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }

    private func formatHours(_ hours: Double) -> String {
        Duration.seconds(hours * 60 * 60).formatted(.units(
            allowed: [.hours, .minutes], width: .narrow, maximumUnitCount: 2,
            fractionalPart: .hide(rounded: .toNearestOrAwayFromZero)
        ))
    }
}

// MARK: - Places

struct PlacesListView: View {
    let places: [CollectionsAggregator.PlaceEntry]
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .mostVisited
    @State private var indexMemo = SearchMemo<
        ListSearchKey<CollectionsAggregator.PlaceEntry>,
        ListSearchIndex<CollectionsAggregator.PlaceEntry>>()

    enum SortOrder: String, CaseIterable {
        case mostVisited = "mostVisited"
        case alphabetical = "alphabetical"

        var displayName: String {
            switch self {
            case .mostVisited:
                String(localized: "collections.places.sort.most-visited", defaultValue: "Most Visited", comment: "Places collection sort order for most visited first.")
            case .alphabetical:
                String(localized: "collections.places.sort.alphabetical", defaultValue: "A to Z", comment: "Places collection sort order for alphabetical order.")
            }
        }
    }

    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var displayed: [CollectionsAggregator.PlaceEntry] {
        var result = places
        if !query.isEmpty {
            // One index per list, rebuilt only when the places or the app
            // language change (not per keystroke, not per row).
            let languageTag = AppLanguagePreference.currentTag()
            let index = indexMemo.value(for: ListSearchKey(entries: places, languageTag: languageTag)) {
                Self.searchIndex(places, languageTag: languageTag)
            }
            result = index.matching(searchText)
        }
        if sortOrder == .alphabetical {
            result = result.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
        return result // aggregator order IS most-visited
    }

    var body: some View {
        let shown = displayed
        List {
            if places.isEmpty {
                ContentUnavailableView(
                    "No Places Yet",
                    systemImage: "building.2",
                    description: Text("Every city, town, and island you stay in shows up here.")
                )
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                // While filtering, the header counts the rows shown.
                Section {
                    ForEach(shown) { place in
                        placeRow(place)
                    }
                } header: {
                    Text(shown.count == 1
                         ? String(localized: "collections.places.count.one", defaultValue: "\(shown.count, format: .number.grouping(.never)) place", comment: "Places collection header for one place.")
                         : String(localized: "collections.places.count.other", defaultValue: "\(shown.count, format: .number.grouping(.never)) places", comment: "Places collection header for multiple places."))
                }
            }
        }
        .navigationTitle("Places")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Place or country")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // A bare menu-style Picker stretches to its widest option
                // in the toolbar; wrapping it in a Menu keeps the control
                // icon-sized.
                Menu {
                    Picker("Sort", selection: $sortOrder) {
                        ForEach(SortOrder.allCases, id: \.self) { order in
                            Text(order.displayName).tag(order)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .accessibilityLabel("Sort order")
                }
            }
        }
    }

    @ViewBuilder
    private func placeRow(_ place: CollectionsAggregator.PlaceEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(place.isoCountryCode.flatMap(flagEmoji(for:)) ?? "🏳️")
                Text(place.name)
                    .font(.subheadline.weight(.semibold))
                kindChip(place.kind)
                Spacer()
                Text(place.tripCount == 1
                     ? (place.dayCount == 1
                        ? String(localized: "collections.place-summary.trip-one.day.one", defaultValue: "\(place.tripCount, format: .number.grouping(.never)) trip · \(place.dayCount, format: .number.grouping(.never)) day", comment: "Place row summary for one trip and one day.")
                        : String(localized: "collections.place-summary.trip-one.day.other", defaultValue: "\(place.tripCount, format: .number.grouping(.never)) trip · \(place.dayCount, format: .number.grouping(.never)) days", comment: "Place row summary for one trip and multiple days."))
                     : (place.dayCount == 1
                        ? String(localized: "collections.place-summary.trip-other.day.one", defaultValue: "\(place.tripCount, format: .number.grouping(.never)) trips · \(place.dayCount, format: .number.grouping(.never)) day", comment: "Place row summary for multiple trips and one day.")
                        : String(localized: "collections.place-summary.trip-other.day.other", defaultValue: "\(place.tripCount, format: .number.grouping(.never)) trips · \(place.dayCount, format: .number.grouping(.never)) days", comment: "Place row summary for multiple trips and multiple days.")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if !place.localities.isEmpty {
                Text(includesLine(place.localities))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private func includesLine(_ localities: [String]) -> String {
        let shown = localities.prefix(3).joined(separator: ", ")
        let extra = localities.count - min(localities.count, 3)
        guard extra > 0 else {
            return String(localized: "collections.place.includes", defaultValue: "Includes \(shown)", comment: "Place row detail listing included localities without an additional count.")
        }
        return extra == 1
            ? String(localized: "collections.place.includes-more.one", defaultValue: "Includes \(shown) +\(extra, format: .number.grouping(.never))", comment: "Place row detail listing localities and one additional locality.")
            : String(localized: "collections.place.includes-more.other", defaultValue: "Includes \(shown) +\(extra, format: .number.grouping(.never))", comment: "Place row detail listing localities and multiple additional localities.")
    }

    @ViewBuilder
    private func kindChip(_ kind: CollectionsAggregator.PlaceKind) -> some View {
        Text(kindLabel(kind))
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: .capsule)
            .foregroundStyle(.secondary)
    }

    private func kindLabel(_ kind: CollectionsAggregator.PlaceKind) -> String {
        switch kind {
        case .metro: String(localized: "collections.place-kind.city", defaultValue: "City", comment: "Places collection kind label for a metropolitan city.")
        case .island: String(localized: "collections.place-kind.island", defaultValue: "Island", comment: "Places collection kind label for an island.")
        case .locality: String(localized: "collections.place-kind.town", defaultValue: "Town", comment: "Places collection kind label for a town or locality.")
        case .area: String(localized: "collections.place-kind.area", defaultValue: "Area", comment: "Places collection kind label for a broader area.")
        }
    }
}

extension PlacesListView {
    /// `place` searched as a one-place list, so typo tolerance is not gated
    /// by other places; the list itself uses `matchingPlaces` semantics.
    nonisolated static func placeMatches(
        _ place: CollectionsAggregator.PlaceEntry,
        query: String,
        languageTag: String = AppLanguagePreference.currentTag()
    ) -> Bool {
        !searchIndex([place], languageTag: languageTag).matching(query).isEmpty
    }

    /// Places matching `query` in list order, one index for the whole list.
    nonisolated static func matchingPlaces(
        _ places: [CollectionsAggregator.PlaceEntry],
        query: String,
        languageTag: String = AppLanguagePreference.currentTag()
    ) -> [CollectionsAggregator.PlaceEntry] {
        searchIndex(places, languageTag: languageTag).matching(query)
    }

    /// Place name and its localities as names; the stored country name, the
    /// ISO code's aliases (English and app-language names, `uk`, `holland`)
    /// as countries.
    nonisolated static func searchIndex(
        _ places: [CollectionsAggregator.PlaceEntry],
        languageTag: String
    ) -> ListSearchIndex<CollectionsAggregator.PlaceEntry> {
        var aliasesByISO: [String: [String]] = [:]
        return ListSearchIndex(entries: places, languageTag: languageTag) { place in
            var countries = place.country.map { [$0] } ?? []
            var codes: Set<String> = []
            if let iso = place.isoCountryCode?.uppercased(), !iso.isEmpty {
                let aliases = aliasesByISO[iso]
                    ?? TripSearch.countryAliases(for: [iso], languageTag: languageTag)
                aliasesByISO[iso] = aliases
                countries += aliases
                codes.insert(iso)
            }
            return ([place.name] + place.localities, countries, codes)
        }
    }
}

// MARK: - List search

private nonisolated let listSearchDocumentID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

/// The trip search engine over a plain list: one document per entry, one
/// index per list. Typo tolerance is gated over the whole list,
/// so `iran` does not list Iraq when an Iran row exists. Entries keep list
/// order.
nonisolated struct ListSearchIndex<Entry: Sendable>: Sendable {
    let entries: [Entry]
    let languageTag: String
    let index: TripSearchIndex

    /// `fields` gives an entry's names (place field), its country names
    /// (country field, where connecting words such as "of" drop out) and its
    /// ISO country codes, which region words ("europe") and country names in
    /// other languages match.
    init(
        entries: [Entry],
        languageTag: String,
        fields: (Entry) -> (names: [String], countries: [String], countryCodes: Set<String>)
    ) {
        let normalizer = TripSearchNormalizer()
        self.entries = entries
        self.languageTag = languageTag
        self.index = TripSearchIndex(documents: entries.map { entry in
            let values = fields(entry)
            return TripSearchDocument(
                tripID: listSearchDocumentID,
                fields: [
                    TripSearchField(kind: .place, displayValues: values.names),
                    TripSearchField(kind: .country, displayValues: values.countries),
                ],
                startDate: .distantPast, endDate: nil, startYear: 0, startMonth: 0,
                durationDays: nil, isComplete: true,
                countryCodes: values.countryCodes,
                normalizer: normalizer)
        })
    }

    /// Entries matching `query` strongly or similarly, in list order. An
    /// empty query lists everything; one of only symbols lists nothing.
    func matching(_ query: String) -> [Entry] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return entries }
        let terms = TripSearch.terms(query, languageTag: languageTag)
        guard !terms.isEmpty else { return [] }
        return TripSearch.match(terms: terms, in: index).map { entries[$0.documentIndex] }
    }
}

/// The inputs a list's search index is built from.
nonisolated struct ListSearchKey<Entry: Equatable>: Equatable {
    let entries: [Entry]
    let languageTag: String
}

/// View-owned memo for derived search state (a list's index). Held in
/// `@State` as a reference, so `body` can build it on first use without
/// writing state during a view update; rebuilt only when `Key` changes.
final class SearchMemo<Key: Equatable, Value> {
    private var cached: (key: Key, value: Value)?

    func value(for key: Key, build: () -> Value) -> Value {
        if let cached, cached.key == key { return cached.value }
        let value = build()
        cached = (key, value)
        return value
    }
}
