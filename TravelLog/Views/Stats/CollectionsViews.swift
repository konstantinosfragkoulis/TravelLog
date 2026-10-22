//
//  CollectionsViews.swift
//  TravelLog
//
//  The Stats "Collections" surface: a card of rows pushing the
//  three collection lists — Airports visited, the inferred Flight Log, and
//  the Places gazetteer. All three render a precomputed
//  `CollectionsAggregator.Collections` value handed down from `StatsView`'s
//  cached aggregates. The flight flow shares an accepted collection owner
//  with Stats and refreshes through the same aggregator while pushed.
//

import SwiftUI
import SwiftData

// MARK: - Stats-tab section

struct CollectionsSectionView: View {
    let collections: CollectionsAggregator.Collections
    /// The rows' subtitles, derived once per aggregate (`StatsOverview`).
    let summary: StatsOverview.CollectionsSummary
    let flightLogModel: FlightLogModel
    let acceptFlightRefresh: FlightLogModel.Acceptance

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Flight Log stays reachable after the last correction or dismissal;
        // an empty log still explains how existing history can be detected.
        StatsSection(title: String(localized: "Collections")) {
            if summary.placeCount > 0 {
                NavigationLink {
                    PlacesListView(places: collections.places)
                } label: {
                    collectionRow(
                        icon: "building.2.fill",
                        title: String(localized: "collections.row.places", defaultValue: "Places", comment: "Collections card row title for the places collection."),
                        count: summary.placeCount,
                        lines: summary.topPlaceNames.isEmpty ? [] : [placesLine]
                    )
                }
                .buttonStyle(.plain)
            }

            if summary.airportCount > 0 {
                if summary.placeCount > 0 { Divider() }
                NavigationLink {
                    AirportsListView(airports: collections.airports)
                } label: {
                    collectionRow(
                        icon: "airplane.circle.fill",
                        title: String(localized: "collections.row.airports", defaultValue: "Airports", comment: "Collections card row title for the airports collection."),
                        count: summary.airportCount,
                        lines: airportLines
                    )
                }
                .buttonStyle(.plain)
            }

            Group {
                if summary.placeCount > 0 || summary.airportCount > 0 { Divider() }
                NavigationLink {
                    FlightLogView(
                        model: flightLogModel,
                        acceptRefresh: acceptFlightRefresh
                    )
                } label: {
                    collectionRow(
                        icon: "airplane.departure",
                        title: String(localized: "collections.row.flights", defaultValue: "Flights", comment: "Collections card row title for the flights collection."),
                        count: collections.flights.count,
                        badge: summary.reviewCount == 0
                            ? nil
                            : (summary.reviewCount == 1
                               ? String(localized: "collections.flights.to-review.one", defaultValue: "\(summary.reviewCount, format: .number.grouping(.never)) to review", comment: "Collections flight row detail when one possible flight needs review.")
                               : String(localized: "collections.flights.to-review.other", defaultValue: "\(summary.reviewCount, format: .number.grouping(.never)) to review", comment: "Collections flight row detail when multiple possible flights need review.")),
                        lines: flightLines
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// "Velmora, Saltreach and Kelden": the most visited places.
    private var placesLine: String {
        summary.topPlaceNames.formatted(.list(type: .and, width: .narrow).locale(AppLanguagePreference.currentLocale()))
    }

    private var airportLines: [String] {
        guard let code = summary.topAirportCode else { return [] }
        let visits = summary.topAirportVisits
        return [visits == 1
            ? String(localized: "stats.collections.airports.most-used.one", defaultValue: "Most used: \(code), \(visits, format: .number.grouping(.never)) visit", comment: "Stats Collections Airports row subtitle naming the airport code with the most visits, for one visit.")
            : String(localized: "stats.collections.airports.most-used.other", defaultValue: "Most used: \(code), \(visits, format: .number.grouping(.never)) visits", comment: "Stats Collections Airports row subtitle naming the airport code with the most visits, for several visits.")]
    }

    private var flightLines: [String] {
        guard !collections.flights.isEmpty else { return [] }
        return [String(localized: "flight-log.collections.description", defaultValue: "Your recorded air journeys", comment: "Flights collection row subtitle; records are journeys and may have unrecorded connections.")]
    }

    @ViewBuilder
    private func collectionRow(icon: String, title: String, count: Int, badge: String? = nil, lines: [String]) -> some View {
        // At accessibility sizes the badge wraps below the title, so the
        // title keeps the row's width.
        let titleLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 6))
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(AppTheme.accent)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                titleLayout {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let badge {
                        AppChip(label: Text(badge), style: .attention, small: true)
                    }
                }
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Text(count, format: .number)
                .font(AppTheme.stat(.subheadline, weight: .semibold))
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 3)
                .accessibilityHidden(true)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
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
                FlagView(iso: airport.isoCountryCode, size: .small)
                Text(airport.code)
                    .font(.subheadline.weight(.semibold))
                    .monospaced()
                if airport.flownThrough {
                    Image(systemName: "airplane")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.accent)
                        .accessibilityLabel("Flown through")
                }
                Spacer()
                // A connection the user added is a visit no stay recorded.
                let visits = airport.visitCount
                Text(visits == 1
                     ? String(localized: "collections.airport.visits.one", defaultValue: "\(visits, format: .number.grouping(.never)) visit", comment: "Airport row count for one visit.")
                     : String(localized: "collections.airport.visits.other", defaultValue: "\(visits, format: .number.grouping(.never)) visits", comment: "Airport row count for multiple visits."))
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
    private typealias PresentationID = CollectionsAggregator.FlightRecord.PresentationIdentity
    let model: FlightLogModel
    let acceptRefresh: FlightLogModel.Acceptance

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var saveFailed = false
    @State private var actionRejected = false
    /// Disable only the row currently waiting for its guarded write. These
    /// IDs never remove records or become a second history.
    @State private var activeActionIDs: Set<PresentationID> = []
    @State private var awaitingReadbackIDs: [PresentationID: Int] = [:]
    /// The last committed Dismiss or Not a Flight, offered for Undo for a
    /// few seconds.
    @State private var pendingUndo: PendingUndo?
    /// The flight or candidate open in the detail sheet.
    @State private var detail: Detail?
    /// A trip the sheet asked to open, once it has closed.
    @State private var tripAfterDetail: (id: UUID, epoch: FlightLogAuthority.Epoch)?

    private struct Detail: Identifiable {
        let id = UUID()
        let epoch: FlightLogAuthority.Epoch
        let subject: FlightDetailSheet.Subject
        var editTimes = false
        var target: FlightLogAuthority.Target?

        init(subject: FlightDetailSheet.Subject, editTimes: Bool = false) {
            self.subject = subject
            self.editTimes = editTimes
            epoch = FlightLogAuthority.currentEpoch
            switch subject {
            case .flight(let record): target = FlightLogAuthority.Target(record: record, epoch: epoch)
            case .candidate(let candidate): target = FlightLogAuthority.Target(candidate: candidate, epoch: epoch)
            }
        }
    }

    nonisolated private struct PendingUndo: Equatable, Sendable {
        nonisolated enum Kind: Sendable { case dismissal, notFlight }
        /// Restarts the countdown when one undoable action follows another.
        let token = UUID()
        let expiresAt = Date.now.addingTimeInterval(5)
        let kind: Kind
        let receipt: FlightLogAuthority.Receipt
        let presentationID: PresentationID

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.token == rhs.token }
    }

    nonisolated private enum YearFilter: Hashable, Sendable {
        case all
        case year(Int)
        case uncertain
    }

    @State private var searchText = ""
    @State private var yearFilter: YearFilter = .all
    @State private var showsRouteMap = false
    @State private var showsReview = false
    @State private var refreshDate = Date.now

    private var pendingCandidates: [CollectionsAggregator.PossibleFlight] {
        model.collections.possibleFlights
    }

    private var shownFlights: [CollectionsAggregator.FlightRecord] {
        model.collections.flights
    }

    var body: some View {
        let correctedFlights = shownFlights
        let candidates = pendingCandidates
        let snapshot = projection(flights: correctedFlights, candidates: candidates)
        List {
            if model.needsRetry {
                retryRow()
            }
            if !model.hasSnapshot {
                if !model.needsRetry {
                    ProgressView().frame(maxWidth: .infinity)
                }
            } else if correctedFlights.isEmpty && candidates.isEmpty {
                ContentUnavailableView(
                    "No Flights Detected",
                    systemImage: "airplane.departure",
                    description: Text(String(localized: "collections.flights.empty.description", defaultValue: "Flights appear here when Travel Log detects air travel in your recorded locations. For older journeys, try Detect Flights in Settings.", comment: "Flight Log empty-state description; Detect Flights is the Settings button of that name."))
                )
            } else if snapshot.records.isEmpty && snapshot.candidates.isEmpty {
                ContentUnavailableView(
                    String(localized: "flight-log.search.empty.title", defaultValue: "No Matching Journeys", comment: "Flight Log empty state when the selected year and search match no records or candidates."),
                    systemImage: "airplane.departure",
                    description: Text(String(localized: "flight-log.search.empty.description", defaultValue: "Try another year or search for a place, airport or route.", comment: "Flight Log no-results guidance."))
                )
            } else {
                if !snapshot.records.isEmpty {
                    Section {
                        FlightLogSummaryView(summary: snapshot.summary)
                        DisclosureGroup(isExpanded: $showsRouteMap) {
                            if showsRouteMap {
                                FlightRouteMap(records: snapshot.records)
                                    .frame(height: 150)
                                    .padding(.vertical, 4)
                                Text(String(localized: "flight-log.map.caption", defaultValue: "Approximate routes between recorded places.", comment: "Caption below the offline Flight Log map; drawn routes are schematic and do not represent an aircraft track."))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } label: {
                            Label(String(localized: "flight-log.map.title", defaultValue: "Route map", comment: "Flight Log disclosure showing the offline map for the selected journeys."), systemImage: "map")
                                .font(.subheadline)
                        }
                    }
                }

                if !snapshot.candidates.isEmpty {
                    Section {
                        Button {
                            showsReview = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "questionmark.circle")
                                    .foregroundStyle(.orange)
                                    .accessibilityHidden(true)
                                Text(String(localized: "flight-log.review.title", defaultValue: "Review possible flights", comment: "Flight Log row opening the separate possible-flight review list."))
                                    .font(.subheadline)
                                Spacer(minLength: 8)
                                Text(snapshot.candidates.count, format: .number)
                                    .font(AppTheme.stat(.subheadline, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                ForEach(snapshot.sections) { section in
                    Section {
                        ForEach(section.flights, id: \.presentationID) { flight in
                            flightEntry(flight)
                        }
                    } header: {
                        HStack {
                            if let year = section.year {
                                Text(verbatim: String(year))
                            } else {
                                Text(String(localized: "flight-log.year.uncertain", defaultValue: "Date uncertain", comment: "Flight Log section and filter for journeys whose observation window does not establish a year."))
                            }
                            Spacer()
                            Text(section.flights.count, format: .number)
                                .monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Flight Log")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showsReview) {
            reviewList()
        }
        .searchable(text: $searchText, prompt: Text(String(localized: "flight-log.search.prompt", defaultValue: "Place, airport or route", comment: "Flight Log search field placeholder.")))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker(String(localized: "flight-log.year.picker", defaultValue: "Period", comment: "Accessible label for the Flight Log year filter."), selection: $yearFilter) {
                        Text(String(localized: "flight-log.year.all", defaultValue: "All years", comment: "Flight Log filter including every recorded year and uncertain dates."))
                            .tag(YearFilter.all)
                        ForEach(FlightLogProjection.years(in: correctedFlights, candidates: candidates), id: \.self) { year in
                            Text(verbatim: String(year)).tag(YearFilter.year(year))
                        }
                        if correctedFlights.contains(where: { FlightLogProjection.year(of: $0) == nil })
                            || candidates.contains(where: { FlightLogProjection.year(of: $0.record) == nil }) {
                            Text(String(localized: "flight-log.year.uncertain", defaultValue: "Date uncertain", comment: "Flight Log section and filter for journeys whose observation window does not establish a year."))
                                .tag(YearFilter.uncertain)
                        }
                    }
                } label: {
                    Label(periodLabel, systemImage: "calendar")
                        .labelStyle(.titleAndIcon)
                }
                .accessibilityLabel(Text(String(localized: "flight-log.year.accessibility", defaultValue: "Period: \(periodLabel)", comment: "Flight Log year filter accessibility label with the currently selected period.")))
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let pendingUndo {
                undoBar(pendingUndo)
            }
        }
        .animation(.default, value: pendingUndo)
        .task(id: pendingUndo?.token) {
            await expireUndo()
        }
        .task(id: model.key(now: refreshDate)) {
            await model.refresh(key: model.key(now: refreshDate), context: modelContext, accept: acceptRefresh)
        }
        .onAppear {
            model.adoptCurrentGeneration()
            refreshDate = .now
        }
        .onChange(of: model.clearGeneration) { _, _ in resetTransientState() }
        .onChange(of: model.completedRefreshRevision) { _, revision in reconcileReadback(revision) }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in refreshDate = .now }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in refreshDate = .now }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.adoptCurrentGeneration()
                refreshDate = .now
            }
        }
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
        .alert(
            String(localized: "flight-log.action.changed.title", defaultValue: "Journey Changed", comment: "Alert when a flight action no longer matches its current physical journey."),
            isPresented: $actionRejected
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(String(localized: "flight-log.action.changed.description", defaultValue: "Your history changed while this journey was open. Review the refreshed journey before making changes.", comment: "Explanation after a stale, ambiguous, or no-longer-existing flight action is rejected."))
        }
        .sheet(item: $detail, onDismiss: {
            guard let request = tripAfterDetail else { return }
            tripAfterDetail = nil
            guard request.epoch == FlightLogAuthority.currentEpoch else { return }
            TripsTabRouter.shared.requestTrip(request.id)
        }) { detail in
            FlightDetailSheet(subject: detail.subject, editTimes: detail.editTimes,
                              visitedAirportCodes: model.collections.airports.map(\.code),
                              actions: detailActions(detail))
        }
    }

    private var periodLabel: String {
        switch yearFilter {
        case .all:
            String(localized: "flight-log.year.all", defaultValue: "All years", comment: "Flight Log filter including every recorded year and uncertain dates.")
        case .year(let year):
            String(year)
        case .uncertain:
            String(localized: "flight-log.year.uncertain", defaultValue: "Date uncertain", comment: "Flight Log section and filter for journeys whose observation window does not establish a year.")
        }
    }

    private func projection(
        flights: [CollectionsAggregator.FlightRecord],
        candidates: [CollectionsAggregator.PossibleFlight]
    ) -> FlightLogProjection.Snapshot {
        let year: Int?
        if case .year(let selected) = yearFilter { year = selected } else { year = nil }
        return FlightLogProjection.make(
            flights: flights, candidates: candidates, year: year, search: searchText,
            onlyUncertainDates: yearFilter == .uncertain)
    }

    /// Suggestions occupy their own lazy list, rather than pushing a long
    /// recorded history beneath a stack of review cards. Keep the parent's
    /// filters and accepted history live while this destination is open.
    private func reviewList() -> some View {
        List {
            let candidates = projection(flights: shownFlights, candidates: pendingCandidates).candidates
            if model.needsRetry { retryRow() }
            if !model.hasSnapshot {
                if !model.needsRetry { ProgressView().frame(maxWidth: .infinity) }
            } else if candidates.isEmpty {
                ContentUnavailableView(
                    String(localized: "flight-log.review.empty.title", defaultValue: "All Reviewed", comment: "Possible-flight review empty state after the last candidate is resolved."),
                    systemImage: "checkmark.circle",
                    description: Text(String(localized: "flight-log.review.empty.description", defaultValue: "There are no possible flights left in this selection.", comment: "Possible-flight review completion explanation respecting the active year and search."))
                )
            } else {
                Section {
                    ForEach(candidates, id: \.presentationID) { candidate in
                        candidateRow(candidate)
                    }
                } footer: {
                    Text(String(localized: "collections.flights.candidates.footer", defaultValue: "Confirming adds a flight to your log. Dismissing hides the suggestion on this device.", comment: "Flight Log footer under possible flights; dismissals are stored on this device only."))
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(String(localized: "flight-log.review.navigation-title", defaultValue: "Possible Flights", comment: "Title of the separate possible-flight review list."))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if let pendingUndo { undoBar(pendingUndo) }
        }
        .task(id: pendingUndo?.token) {
            await expireUndo()
        }
        .task(id: model.key(now: refreshDate)) {
            await model.refresh(key: model.key(now: refreshDate), context: modelContext, accept: acceptRefresh)
        }
        .onAppear {
            model.adoptCurrentGeneration()
            refreshDate = .now
        }
        .onChange(of: model.clearGeneration) { _, _ in resetTransientState() }
        .onChange(of: model.completedRefreshRevision) { _, revision in reconcileReadback(revision) }
    }

    private func retryRow() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "flight-log.refresh.failed", defaultValue: "Your history could not be refreshed. Try again.", comment: "Flight Log read failure message; failed reads never replace accepted history with empty data."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(String(localized: "flight-log.refresh.retry", defaultValue: "Try Again", comment: "Button retrying an authoritative Flight Log refresh.")) {
                model.requestRefresh()
            }
        }
    }

    private func resetTransientState() {
        activeActionIDs.removeAll()
        awaitingReadbackIDs.removeAll()
        pendingUndo = nil
        detail = nil
        tripAfterDetail = nil
        saveFailed = false
        actionRejected = false
        searchText = ""
        yearFilter = .all
        showsRouteMap = false
        // Keep the stable destination alive. Its current empty/loading state
        // must update, rather than strand the last resolved review row.
    }

    private func reconcileReadback(_ revision: Int) {
        let completed = awaitingReadbackIDs.filter { $0.value <= revision }.map(\.key)
        for id in completed {
            activeActionIDs.remove(id)
            awaitingReadbackIDs.removeValue(forKey: id)
        }
    }

    private func expireUndo() async {
        guard let undo = pendingUndo else { return }
        let token = undo.token
        let remaining = undo.expiresAt.timeIntervalSinceNow
        if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
        guard !Task.isCancelled, pendingUndo?.token == token else { return }
        pendingUndo = nil
    }

    /// The sheet's answers run here, after it closes, through the same
    /// writers as the rows.
    private func detailActions(_ presented: Detail) -> FlightDetailSheet.Actions {
        let subject = presented.subject
        let epoch = presented.epoch
        // `sheet(item:)` supplies the item being presented. Reading another
        // captured copy of the parent's State here can still see nil during
        // presentation, incorrectly hiding every answer in a valid sheet.
        let currentTarget = epoch == FlightLogAuthority.currentEpoch ? presented.target : nil
        let detailState = $detail
        let busyState = $activeActionIDs
        func targetForAction() -> FlightLogAuthority.Target? {
            guard epoch == FlightLogAuthority.currentEpoch else { return nil }
            if let current = detailState.wrappedValue {
                guard current.id == presented.id else { return nil }
                return current.target
            }
            return presented.target
        }
        let isBusy = busyState.wrappedValue.contains(subject.record.presentationID)
        var actions = FlightDetailSheet.Actions()
        actions.canChangeMode = currentTarget != nil && !isBusy
        actions.canEditCorrections = currentTarget != nil && subject.record.canUsePortablePreferences && !isBusy
        actions.mayBeginCorrection = {
            targetForAction() != nil && subject.record.canUsePortablePreferences
                && !busyState.wrappedValue.contains(subject.record.presentationID)
        }
        actions.openTrip = { tripID in
            guard epoch == FlightLogAuthority.currentEpoch else { return }
            tripAfterDetail = (tripID, epoch)
            detail = nil
        }
        switch subject {
        case .candidate(let candidate):
            actions.confirm = { times, clearTimes, stops in
                let target = targetForAction()
                detail = nil
                runAction(.confirm(times: times, clearTimes: clearTimes, stops: stops), target: target,
                          presentationID: candidate.presentationID)
            }
            actions.dismissCandidate = {
                let target = targetForAction()
                detail = nil
                runAction(.dismiss, target: target, presentationID: candidate.presentationID,
                          undoKind: .dismissal)
            }
        case .flight(let flight):
            actions.notAFlight = {
                let target = targetForAction()
                detail = nil
                runAction(.markNotFlight, target: target, presentationID: flight.presentationID,
                          undoKind: .notFlight)
            }
            actions.saveTimes = { times in
                let target = targetForAction()
                runAction(.setTimes(times), target: target, presentationID: flight.presentationID)
            }
            actions.saveStops = { codes in
                let target = targetForAction()
                runAction(.setStops(codes), target: target, presentationID: flight.presentationID)
            }
        }
        return actions
    }

    @ViewBuilder
    private func candidateRow(_ candidate: CollectionsAggregator.PossibleFlight) -> some View {
        let route = Self.spokenRoute(candidate.record)
        VStack(alignment: .leading, spacing: 6) {
            // The places lead (what the user remembers), codes and dates
            // second; the whole block opens the detail sheet.
            Button {
                detail = Detail(subject: .candidate(candidate))
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(FlightLogProjection.primaryRoute(candidate.record))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                            .fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(.primary)
                        Spacer()
                        if activeActionIDs.contains(candidate.presentationID) {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                    }
                    Text(FlightLogProjection.dateText(candidate.record))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(FlightLogProjection.uncertaintyHint(candidate.record)
                         ?? candidate.evidenceDisplayText
                         ?? String(localized: "collections.flight-candidate.evidence.fallback", defaultValue: "Flight-shaped leg", comment: "Fallback evidence description for a possible flight."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityHint(Text(String(localized: "collections.flight-candidate.details.hint", defaultValue: "Shows where you were before and after, and why this might be a flight.", comment: "VoiceOver hint on a possible flight row that opens its detail sheet.")))
            // `.borderless` is the one button style List treats as plain
            // inline content — the bordered styles lose the geometry
            // negotiation with the row (stretched wide, then tall). Explicit
            // capsule labels give them
            // their shape instead, matching the kind-chip language.
            let actionLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(spacing: 10))
            actionLayout {
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
                .disabled(activeActionIDs.contains(candidate.presentationID)
                          || FlightLogAuthority.Target(candidate: candidate) == nil)
                .accessibilityLabel(route.map {
                    Text(String(localized: "collections.flight-candidate.confirm.accessibility", defaultValue: "Confirm flight from \($0.from) to \($0.to)", comment: "VoiceOver label for confirming a possible flight; the places or airport codes at each end."))
                } ?? Text("Confirm Flight"))

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
                .disabled(activeActionIDs.contains(candidate.presentationID)
                          || !candidate.record.canUsePortablePreferences
                          || FlightLogAuthority.Target(candidate: candidate) == nil)
                .accessibilityLabel(route.map {
                    Text(String(localized: "collections.flight-candidate.dismiss.accessibility", defaultValue: "Dismiss possible flight from \($0.from) to \($0.to)", comment: "VoiceOver label for dismissing a possible flight; the places or airport codes at each end."))
                } ?? Text("Dismiss"))
            }
        }
        .padding(.vertical, 4)
        .disabled(activeActionIDs.contains(candidate.presentationID))
    }

    /// The ends VoiceOver names: place names when known, else codes.
    private static func spokenRoute(
        _ record: CollectionsAggregator.FlightRecord
    ) -> (from: String, to: String)? {
        guard let from = record.departurePlace ?? record.departureCode,
              let to = record.arrivalPlace ?? record.arrivalCode else { return nil }
        return (from, to)
    }

    private func confirmCandidate(
        _ candidate: CollectionsAggregator.PossibleFlight, times: FlightTimeOverrides.Times? = nil,
        stops: [String]? = nil
    ) {
        runAction(.confirm(times: times, stops: stops),
                  target: FlightLogAuthority.Target(candidate: candidate),
                  presentationID: candidate.presentationID)
    }

    private func markNotAFlight(_ flight: CollectionsAggregator.FlightRecord) {
        runAction(.markNotFlight, target: FlightLogAuthority.Target(record: flight),
                  presentationID: flight.presentationID, undoKind: .notFlight)
    }

    private func dismissCandidate(_ candidate: CollectionsAggregator.PossibleFlight) {
        runAction(.dismiss, target: FlightLogAuthority.Target(candidate: candidate),
                  presentationID: candidate.presentationID, undoKind: .dismissal)
    }

    private func performUndo(_ undo: PendingUndo) {
        // Admit this bar's receipt once, before transferring its readback.
        guard let current = pendingUndo,
              current.token == undo.token,
              current.receipt == undo.receipt,
              current.presentationID == undo.presentationID,
              current.receipt.target.epoch == FlightLogAuthority.currentEpoch,
              current.expiresAt > .now else { return }
        pendingUndo = nil
        // Its write has already committed. Undo owns the receipt's separate
        // operation, even if the first readback is still in flight.
        activeActionIDs.remove(current.presentationID)
        awaitingReadbackIDs.removeValue(forKey: current.presentationID)
        runAction(.undo(current.receipt), target: current.receipt.target,
                  presentationID: current.presentationID,
                  retryUndo: current)
    }

    /// The guarded writer validates a fresh physical journey and returns an
    /// explicit outcome. Until authoritative aggregation accepts the change,
    /// this row stays visible and busy instead of inventing/hiding history.
    private func runAction(
        _ action: FlightLogAuthority.Action, target: FlightLogAuthority.Target?,
        presentationID: PresentationID, undoKind: PendingUndo.Kind? = nil,
        retryUndo: PendingUndo? = nil
    ) {
        guard let target else {
            actionRejected = true
            model.requestRefresh()
            return
        }
        guard activeActionIDs.insert(presentationID).inserted else {
            // A second edit can arrive before SwiftUI renders the disabled
            // state. Its sheet may already hold a local draft; close it so
            // an unsubmitted value cannot masquerade as a saved correction.
            detail = nil
            return
        }
        let epoch = target.epoch
        let detailState = $detail
        Task {
            let result = await PipelineGate.shared.runReturning(touching: [.stay]) {
                await Self.applyAction(action, target: target)
            }
            // A wipe revokes UI work before its store unit runs. Neither an
            // error/Undo nor a correction from that older history may return.
            guard epoch == FlightLogAuthority.currentEpoch else { return }
            switch result.status {
            case .committed:
                if let updatedTarget = result.updatedTarget,
                   var current = detailState.wrappedValue, current.target == target {
                    current.target = updatedTarget
                    detailState.wrappedValue = current
                }
                if let undoKind, let receipt = result.receipt {
                    pendingUndo = PendingUndo(kind: undoKind, receipt: receipt,
                                              presentationID: presentationID)
                }
                awaitingReadbackIDs[presentationID] = model.requestRefresh()
            case .unchanged:
                if let updatedTarget = result.updatedTarget,
                   var current = detailState.wrappedValue, current.target == target {
                    current.target = updatedTarget
                    detailState.wrappedValue = current
                }
                awaitingReadbackIDs[presentationID] = model.requestRefresh()
            case .rejected:
                activeActionIDs.remove(presentationID)
                detail = nil
                actionRejected = true
                model.requestRefresh()
            case .failed:
                activeActionIDs.remove(presentationID)
                detail = nil
                if let retryUndo {
                    pendingUndo = PendingUndo(kind: retryUndo.kind, receipt: retryUndo.receipt,
                                              presentationID: retryUndo.presentationID)
                }
                saveFailed = true
            }
        }
    }

    @MainActor
    private static func applyAction(_ action: FlightLogAuthority.Action,
                                    target: FlightLogAuthority.Target) -> FlightLogAuthority.Result {
        FlightLogAuthority.apply(action, target: target, context: AppDelegate.modelContainer.mainContext)
    }

    @ViewBuilder
    private func undoBar(_ undo: PendingUndo) -> some View {
        HStack(spacing: 12) {
            Group {
                switch undo.kind {
                case .dismissal:
                    Text(String(localized: "collections.flight-undo.dismissed", defaultValue: "Suggestion dismissed", comment: "Flight Log undo bar message after dismissing a possible flight."))
                case .notFlight:
                    Text(String(localized: "collections.flight-undo.not-flight", defaultValue: "Marked as not a flight", comment: "Flight Log undo bar message after marking a flight as not a flight."))
                }
            }
            .font(.subheadline)
            Spacer(minLength: 8)
            Button(String(localized: "collections.flight-undo.undo", defaultValue: "Undo", comment: "Flight Log undo bar button that reverses the last dismissal or Not a Flight.")) {
                performUndo(undo)
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: .capsule)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    static func formatGap(_ hours: Double) -> String {
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

    /// The endpoint zones a record's dates read in: each stay's own, the
    /// device zone for either one unknown (older snapshots, unstamped stays).
    private static func displayZones(
        _ record: CollectionsAggregator.FlightRecord
    ) -> (departure: TimeZone, arrival: TimeZone) {
        (StayTimeZone.resolve(record.departureTimeZoneIdentifier),
         StayTimeZone.resolve(record.arrivalTimeZoneIdentifier))
    }

    /// Honest date display: location data only brackets a flight between
    /// the last fix at the origin and the first fix at the destination —
    /// for photo-era legs that window spans days, so a single date is
    /// wrong by up to the gap. Same-day windows render as one date; wider
    /// ones as a range. Each end reads as the civil day where the user
    /// was (the window start in the departure stay's zone, the arrival in
    /// the arrival stay's), whatever zone the device is in now. Across the
    /// date line the arrival's date can precede the departure's; both
    /// then show, in travel order.
    /// Times the user set (`FlightTimeOverrides`) stand in for the window.
    static func flightDateText(_ record: CollectionsAggregator.FlightRecord) -> String {
        let zones = displayZones(record)
        let landed = record.userArrival ?? record.date
        guard let end = TravelDays.label(for: landed, zone: zones.arrival) else {
            return landed.formatted(.dateTime.day().month(.abbreviated).year())
        }
        // Day labels are civil dates at UTC midnight, so they format in UTC.
        let labelZone = TravelDays.labelCalendar.timeZone
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated).year()
        style.timeZone = labelZone
        guard let windowStart = record.userDeparture ?? record.departureWindowStart,
              let start = TravelDays.label(for: windowStart, zone: zones.departure),
              start != end else {
            return end.formatted(style)
        }
        guard start < end else {
            let departure = start.formatted(style)
            let arrival = end.formatted(style)
            return String(
                localized: "collections.flight-date.reversed",
                defaultValue: "\(departure) → \(arrival)",
                comment: "Flight dates when the arrival's local date is earlier than the departure's (crossing the date line): departure date, then arrival date."
            )
        }
        return DateRangeText.format(
            start..<end, Date.IntervalFormatStyle(date: .abbreviated, time: .omitted, timeZone: labelZone)
        )
    }

    /// Confirmed flights by year of their displayed (arrival) date, newest
    /// year first, each keeping the log's order.
    struct YearSection: Identifiable {
        let year: Int
        var flights: [CollectionsAggregator.FlightRecord]
        var id: Int { year }
    }

    static func yearSections(_ flights: [CollectionsAggregator.FlightRecord]) -> [YearSection] {
        var sections: [YearSection] = []
        var indexByYear: [Int: Int] = [:]
        for flight in flights {
            let arrival = flight.userArrival ?? flight.date
            let label = TravelDays.label(for: arrival, zone: displayZones(flight).arrival) ?? arrival
            let year = TravelDays.labelCalendar.component(.year, from: label)
            if let index = indexByYear[year] {
                sections[index].flights.append(flight)
            } else {
                indexByYear[year] = sections.count
                sections.append(YearSection(year: year, flights: [flight]))
            }
        }
        return sections.sorted { $0.year > $1.year }
    }

    /// Every row opens the same flight detail, including rows linked to a
    /// trip. Open Trip remains an explicit secondary action.
    @ViewBuilder
    private func flightEntry(_ flight: CollectionsAggregator.FlightRecord) -> some View {
        let notAFlight = String(localized: "collections.flight.not-a-flight", defaultValue: "Not a Flight", comment: "Flight Log action that removes a flight the user says was not a flight.")
        let editTimes = String(localized: "collections.flight.edit-times", defaultValue: "Edit Times", comment: "Flight Log action that edits a flight's departure and arrival times.")
        Button {
            detail = Detail(subject: .flight(flight))
        } label: {
            flightRow(flight)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if flight.canUsePortablePreferences, FlightLogAuthority.Target(record: flight) != nil {
                Button {
                    detail = Detail(subject: .flight(flight), editTimes: true)
                } label: {
                    Label(editTimes, systemImage: "clock")
                }
                .tint(AppTheme.accent)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if FlightLogAuthority.Target(record: flight) != nil {
                Button {
                    markNotAFlight(flight)
                } label: {
                    Label(notAFlight, systemImage: TransitMode.notFlight.systemImage)
                }
                .tint(.orange)
            }
        }
        .contextMenu {
            if let tripID = flight.tripID {
                Button {
                    TripsTabRouter.shared.requestTrip(tripID)
                } label: {
                    Label(String(localized: "flight-log.open-trip", defaultValue: "Open Trip", comment: "Secondary flight action opening the associated trip."), systemImage: "suitcase")
                }
            }
            Button {
                detail = Detail(subject: .flight(flight))
            } label: {
                Label(String(localized: "collections.flight.details", defaultValue: "Flight Details", comment: "Flight Log action that opens a flight's detail sheet."),
                      systemImage: "info.circle")
            }
            if flight.canUsePortablePreferences, FlightLogAuthority.Target(record: flight) != nil {
                Button {
                    detail = Detail(subject: .flight(flight), editTimes: true)
                } label: {
                    Label(editTimes, systemImage: "clock")
                }
            }
            if FlightLogAuthority.Target(record: flight) != nil {
                Button {
                    markNotAFlight(flight)
                } label: {
                    Label(notAFlight, systemImage: TransitMode.notFlight.systemImage)
                }
            }
        }
        .disabled(activeActionIDs.contains(flight.presentationID))
    }

    @ViewBuilder
    private func flightRow(_ flight: CollectionsAggregator.FlightRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(FlightLogProjection.primaryRoute(flight))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if activeActionIDs.contains(flight.presentationID) {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            Text(FlightLogProjection.dateText(flight))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let hint = FlightLogProjection.uncertaintyHint(flight) {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(String(localized: "flight-log.row.details-hint", defaultValue: "Opens flight details and corrections.", comment: "VoiceOver hint for a recorded flight journey row.")))
    }

    static func formatHours(_ hours: Double) -> String {
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
    @State private var preparedIndex: ListSearchIndex<CollectionsAggregator.PlaceEntry>?

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
        // Keep the unfiltered list visible while the current index prepares.
        if !query.isEmpty, let index = preparedIndex,
           index.entries == places, index.languageTag == AppLanguagePreference.currentTag() {
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
        let languageTag = AppLanguagePreference.currentTag()
        let shown = displayed
        List {
            if places.isEmpty {
                ContentUnavailableView(
                    "No Places Yet",
                    systemImage: "building.2",
                    description: Text(String(localized: "collections.places.empty.description", defaultValue: "Cities, towns, and islands from your trips appear here.", comment: "Places collection empty-state description; the list holds trip destinations only."))
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
        .task(id: ListSearchKey(entries: places, languageTag: languageTag)) {
            if let index = preparedIndex, index.entries == places, index.languageTag == languageTag { return }
            let places = places
            let build = Task.detached(priority: .userInitiated) {
                Self.searchIndex(places, languageTag: languageTag)
            }
            let index = await build.value
            guard !Task.isCancelled else { return }
            preparedIndex = index
        }
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
                FlagView(iso: place.isoCountryCode, size: .small)
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
    #if DEBUG
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
    #endif

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
