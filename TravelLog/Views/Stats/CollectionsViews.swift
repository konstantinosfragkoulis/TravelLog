//
//  CollectionsViews.swift
//  TravelLog
//
//  The Stats "Collections" surface: a card of rows pushing the
//  three collection lists — Airports visited, the inferred Flight Log, and
//  the Places gazetteer. All three render a precomputed
//  `CollectionsAggregator.Collections` value handed down from `StatsView`'s
//  cached aggregates — no fetching, no recompute on push. The Flight Log
//  hosts Stats' refresh while it is on screen.
//

import SwiftUI
import SwiftData

// MARK: - Stats-tab section

struct CollectionsSectionView: View {
    let collections: CollectionsAggregator.Collections
    /// The rows' subtitles, derived once per aggregate (`StatsOverview`).
    let summary: StatsOverview.CollectionsSummary
    /// Stats' refresh, which the Flight Log hosts while it is on screen.
    let refresh: StatsRefreshDriver

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Rows with nothing behind them are left out; with none, the card.
        // The Flights row stays while the card shows, so the last answer in
        // an open Flight Log never pops it.
        if !summary.isEmpty {
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

                if summary.placeCount > 0 || summary.airportCount > 0 { Divider() }
                NavigationLink {
                    FlightLogView(collections: collections, refresh: refresh)
                } label: {
                    collectionRow(
                        icon: "airplane.departure",
                        title: String(localized: "collections.row.flights", defaultValue: "Flights", comment: "Collections card row title for the flights collection."),
                        count: summary.flightCount,
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
        var lines: [String] = []
        if summary.kmFlown > 0 {
            let distance = UnitsFormatter.formatDistance(kilometers: summary.kmFlown)
            let around = summary.kmFlown / 40_075
            lines.append(around >= 0.1
                ? String(localized: "stats.collections.flights.distance-around", defaultValue: "\(distance) flown · \(around, format: .number.precision(.fractionLength(1)))× around the Earth", comment: "Stats Collections Flights row subtitle: distance flown, then how many times around the Earth that is, such as 1.5×.")
                : String(localized: "stats.collections.flights.distance", defaultValue: "\(distance) flown", comment: "Stats Collections Flights row subtitle with the distance flown."))
        }
        if let route = summary.longestFlightRoute, summary.longestFlightKm > 0 {
            lines.append(String(localized: "stats.collections.flights.longest", defaultValue: "Longest: \(route), \(UnitsFormatter.formatDistance(kilometers: summary.longestFlightKm))", comment: "Stats Collections Flights row subtitle with the longest flight's route and distance."))
        }
        return lines
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
    typealias PresentationID = CollectionsAggregator.FlightRecord.PresentationIdentity

    let collections: CollectionsAggregator.Collections
    /// Stats' refresh, hosted here while the log or its review is on screen.
    let refresh: StatsRefreshDriver

    @State private var searchText = ""
    @State private var showsReview = false
    @State private var showsTotals = false
    /// The user's answers, shown at once until a refreshed log carries them.
    @State private var overlay = FlightLogOverlay()
    /// Why the last answer did not land, for the alert.
    @State private var refusal: FlightDetailSheet.Refusal?
    /// The last committed Dismiss or Not a Flight, offered for Undo for a
    /// few seconds.
    @State private var pendingUndo: PendingUndo?
    /// The flight or candidate open in the detail sheet.
    @State private var detail: Detail?
    /// A trip the sheet asked to open, once it has closed.
    @State private var tripAfterDetail: UUID?
    /// Each row's answers run in order, so an edit made while an earlier
    /// one is still saving checks what that one wrote.
    @State private var actionChains: [PresentationID: Task<Void, Never>] = [:]
    @State private var indexMemo = SearchMemo<
        ListSearchKey<CollectionsAggregator.FlightRecord>,
        ListSearchIndex<CollectionsAggregator.FlightRecord>>()

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private struct Detail: Identifiable {
        let id = UUID()
        let subject: FlightDetailSheet.Subject
        var editTimes = false
        /// What the sheet's answers may write, captured when it opened.
        let target: FlightLogAuthority.Target?

        init(subject: FlightDetailSheet.Subject, editTimes: Bool = false) {
            self.subject = subject
            self.editTimes = editTimes
            switch subject {
            case .candidate(let candidate): target = FlightLogAuthority.Target(candidate: candidate)
            case .flight(let flight): target = FlightLogAuthority.Target(record: flight)
            }
        }
    }

    private struct PendingUndo: Equatable {
        enum Kind { case dismissal, notFlight }
        /// Restarts the countdown when one undoable action follows another.
        let token = UUID()
        let kind: Kind
        let receipt: FlightLogAuthority.Receipt
        let presentationID: PresentationID

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.token == rhs.token }
    }

    private static let undoSeconds = 5

    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let flights = overlay.flights(collections.flights)
        let candidates = overlay.candidates(collections.possibleFlights)
        let shown = filtered(flights)
        presentations(List {
            if flights.isEmpty && candidates.isEmpty {
                ContentUnavailableView(
                    "No Flights Detected",
                    systemImage: "airplane.departure",
                    description: Text(String(localized: "collections.flights.empty.description", defaultValue: "Flights appear here when Travel Log detects air travel in your recorded locations. For older journeys, try Detect Flights in Settings.", comment: "Flight Log empty-state description; Detect Flights is the Settings button of that name."))
                )
            } else {
                // A search puts its results first, under one line of their
                // totals; the log sits under its summary, which opens every total.
                if !candidates.isEmpty, query.isEmpty {
                    reviewEntry(count: candidates.count)
                }
                if !shown.isEmpty {
                    let stats = CollectionsAggregator.flightStats(from: shown)
                    if query.isEmpty { summaryCard(stats) } else { totalsLine(stats) }
                    ForEach(Self.yearSections(shown)) { section in
                        Section {
                            ForEach(section.flights, id: \.presentationID) { flight in
                                flightEntry(flight, inYear: section.year)
                            }
                        } header: {
                            HStack {
                                Text(verbatim: "\(section.year)")
                                Spacer()
                                let count = section.flights.count
                                Text(count == 1
                                     ? String(localized: "collections.flights.year-count.one", defaultValue: "\(count, format: .number.grouping(.never)) flight", comment: "Flight Log year section count for one flight.")
                                     : String(localized: "collections.flights.year-count.other", defaultValue: "\(count, format: .number.grouping(.never)) flights", comment: "Flight Log year section count for multiple flights."))
                                    .monospacedDigit()
                            }
                        }
                    }
                } else if !flights.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .environment(\.defaultMinListRowHeight, 34)
        // The search field above already separates the chip from the bar.
        .contentMargins(.top, 4, for: .scrollContent), active: !showsReview)
        .navigationTitle("Flight Log")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text(String(localized: "flight-log.search.prompt", defaultValue: "Place, airport or route", comment: "Flight Log search field placeholder.")))
        .navigationDestination(isPresented: $showsReview) {
            reviewList
        }
        .sheet(isPresented: $showsTotals) {
            FlightTotalsSheet(flights: filtered(flights), selection: selectionTitle)
        }
        .onChange(of: collections) { _, collections in
            overlay.reconcile(with: collections)
        }
    }

    /// The review queue on its own page, so a long log never sits under a
    /// stack of questions.
    private var reviewList: some View {
        let candidates = overlay.candidates(collections.possibleFlights)
        return presentations(List {
            if candidates.isEmpty {
                ContentUnavailableView(
                    String(localized: "flight-log.review.empty.title", defaultValue: "All Reviewed", comment: "Possible-flight review empty state after the last candidate is resolved."),
                    systemImage: "checkmark.circle")
            } else {
                Section {
                    ForEach(candidates, id: \.presentationID) { candidate in
                        candidateRow(candidate)
                    }
                } footer: {
                    Text(String(localized: "collections.flights.candidates.footer", defaultValue: "Confirming adds a flight to your log. Dismissing hides the suggestion on this device.", comment: "Flight Log footer under possible flights; dismissals are stored on this device only."))
                }
            }
        }, active: showsReview)
        .navigationTitle("Possible Flights")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// What both pages share: the Stats refresh, the Undo bar, the save
    /// alert and the detail sheet. Only the page on top presents.
    private func presentations(_ list: some View, active: Bool) -> some View {
        list
            .refreshesStats(refresh)
            .safeAreaInset(edge: .bottom) {
                if let pendingUndo {
                    undoBar(pendingUndo)
                }
            }
            .animation(.default, value: pendingUndo)
            .task(id: pendingUndo?.token) {
                guard pendingUndo != nil else { return }
                try? await Task.sleep(for: .seconds(Self.undoSeconds))
                guard !Task.isCancelled else { return }
                pendingUndo = nil
            }
            .alert(refusal?.title ?? "", isPresented: Binding(
                get: { active && refusal != nil }, set: { if !$0 { refusal = nil } })
            ) {
                Button("OK", role: .cancel) {}
            }
            .sheet(item: active ? $detail : .constant(nil), onDismiss: {
                guard let tripID = tripAfterDetail else { return }
                tripAfterDetail = nil
                TripsTabRouter.shared.requestTrip(tripID)
            }) { detail in
                FlightDetailSheet(subject: detail.subject, editTimes: detail.editTimes,
                                  visitedAirportCodes: collections.airports.map(\.code),
                                  actions: detailActions(detail))
            }
    }

    // MARK: Filters

    private func filtered(_ flights: [CollectionsAggregator.FlightRecord]) -> [CollectionsAggregator.FlightRecord] {
        var result = flights
        if !query.isEmpty {
            let languageTag = AppLanguagePreference.currentTag()
            let index = indexMemo.value(for: ListSearchKey(entries: flights, languageTag: languageTag)) {
                Self.searchIndex(flights, languageTag: languageTag)
            }
            result = index.matching(query)
        }
        return result
    }

    private func reviewEntry(count: Int) -> some View {
        Section {
            Button {
                showsReview = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(AppTheme.attention)
                        .accessibilityHidden(true)
                    Text(String(localized: "flight-log.review.title", defaultValue: "Review possible flights", comment: "Flight Log row opening the separate possible-flight review list."))
                        .font(.subheadline)
                    Spacer(minLength: 8)
                    Text(count, format: .number)
                        .font(AppTheme.stat(.subheadline, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        // The summary follows it closely, both above the log.
        .listSectionSpacing(.custom(12))
    }

    // MARK: Totals

    /// What the totals cover: every year.
    private var selectionTitle: String {
        String(localized: "flight-log.year.all", defaultValue: "All years", comment: "Flight Log summary heading: the totals cover flights from every year.")
    }

    /// The selection's totals at a glance: flights, distance and air time,
    /// then the Earth comparison and the longest route. Opens every total.
    private func summaryCard(_ stats: CollectionsAggregator.FlightStats) -> some View {
        let count = stats.totalFlights
        let figuresLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
        // At accessibility sizes the link drops under the heading.
        let headerLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        return Section {
            Button {
                showsTotals = true
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    headerLayout {
                        Text(selectionTitle)
                            .font(AppTheme.eyebrow)
                            .textCase(.uppercase)
                            .foregroundStyle(AppTheme.onFieldSecondary)
                        if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                        HStack(spacing: 4) {
                            Text(String(localized: "flight-log.summary.all-totals", defaultValue: "All Totals", comment: "Flight Log summary card link opening every flight total for the selected years."))
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .accessibilityHidden(true)
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                    figuresLayout {
                        summaryFigure(StatsText.grouped(count), label: count == 1
                            ? String(localized: "flight-log.summary.flights.one", defaultValue: "flight", comment: "Flight Log summary label under the number of flights, for one flight.")
                            : String(localized: "flight-log.summary.flights.other", defaultValue: "flights", comment: "Flight Log summary label under the number of flights, for several flights."))
                        // Unknown without any route geometry or estimate.
                        if stats.totalKm > 0 {
                            let distance = UnitsFormatter.distanceParts(kilometers: stats.totalKm)
                            summaryFigure(distance.value, label: String(localized: "flight-log.summary.distance", defaultValue: "\(distance.unit) flown", comment: "Flight Log summary label under the distance flown; the placeholder is the unit, such as km or mi."))
                        }
                        if stats.totalEstimatedHours > 0 {
                            summaryFigure("≈ \(Self.summaryHours(stats.totalEstimatedHours))", label: String(localized: "flight-log.summary.hours", defaultValue: "in the air", comment: "Flight Log summary label under the estimated time spent flying."))
                        }
                    }
                    if let line = Self.summaryLine(stats) {
                        Text(line)
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.onFieldSecondary)
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .foregroundStyle(AppTheme.onField)
                .padding(.vertical, 4)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            // The Passport's cobalt field, light text in either mode.
            .listRowBackground(FlightLogSummaryField())
        }
    }

    private func summaryFigure(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: value)
                .font(AppTheme.stat(.title2))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.footnote)
                .foregroundStyle(AppTheme.onFieldSecondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "193h" past ten hours, where minutes add nothing to a total; "7h 44m"
    /// under it.
    static func summaryHours(_ hours: Double) -> String {
        guard hours >= 10 else { return formatHours(hours) }
        return Duration.seconds(hours * 60 * 60).formatted(.units(
            allowed: [.hours], width: .narrow,
            fractionalPart: .hide(rounded: .toNearestOrAwayFromZero)
        ))
    }

    /// "3,2× around the Earth · longest AMS → SIN": the comparison from half
    /// the Earth, the longest route among two flights or more; nil for
    /// neither.
    static func summaryLine(_ stats: CollectionsAggregator.FlightStats) -> String? {
        let around = stats.totalKm / 40_075
        let longest = stats.totalFlights > 1 && stats.longestKm > 0 ? stats.longestRouteLabel : nil
        switch (around >= 0.5, longest) {
        case (true, let route?):
            return String(localized: "flight-log.summary.around-longest", defaultValue: "\(around, format: .number.precision(.fractionLength(1)))× around the Earth · longest \(route)", comment: "Flight Log summary line: how many times around the Earth the distance flown is, such as 3.2×, then the longest flight's route.")
        case (true, nil):
            return String(localized: "flight-log.summary.around", defaultValue: "\(around, format: .number.precision(.fractionLength(1)))× around the Earth", comment: "Flight Log summary line: how many times around the Earth the distance flown is, such as 3.2×.")
        case (false, let route?):
            return String(localized: "flight-log.summary.longest", defaultValue: "Longest \(route)", comment: "Flight Log summary line naming the longest flight's route, such as AMS → SIN.")
        case (false, nil):
            return nil
        }
    }

    /// The totals of a search in one line: "3 flights · 4.862 km
    /// · ≈ 7h 44m".
    private func totalsLine(_ stats: CollectionsAggregator.FlightStats) -> some View {
        let count = stats.totalFlights
        let flights = count == 1
            ? String(localized: "collections.flights.year-count.one", defaultValue: "\(count, format: .number.grouping(.never)) flight", comment: "Flight Log year section count for one flight.")
            : String(localized: "collections.flights.year-count.other", defaultValue: "\(count, format: .number.grouping(.never)) flights", comment: "Flight Log year section count for multiple flights.")
        let measures = Self.distanceAndDuration(km: stats.totalKm, hours: stats.totalEstimatedHours, estimated: true)
        return Section {
            Text(verbatim: ([flights] + [measures].compactMap { $0 }).joined(separator: " · "))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                // Under the year headers' text.
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .listRowBackground(Color.clear)
        }
        .listSectionSpacing(.custom(8))
    }

    // MARK: Possible flights

    @ViewBuilder
    private func candidateRow(_ candidate: CollectionsAggregator.PossibleFlight) -> some View {
        let record = candidate.record
        let route = Self.spokenRoute(record)
        let target = FlightLogAuthority.Target(candidate: candidate)
        let date = Self.flightDateText(record)
        VStack(alignment: .leading, spacing: 8) {
            // The places lead (what the user remembers), codes and dates
            // second; the whole block opens the detail sheet. Plain colours:
            // a borderless button resolves `.primary` to the accent tint.
            Button {
                detail = Detail(subject: .candidate(candidate))
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(record.placeRouteLabel ?? record.routeLabel)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color(.tertiaryLabel))
                            .accessibilityHidden(true)
                    }
                    Text(verbatim: record.placeRouteLabel == nil ? date : "\(record.routeLabel) · \(date)")
                    Text(verbatim: ([UnitsFormatter.formatDistance(kilometers: record.distanceKm)]
                                    + [candidate.evidenceDisplayText].compactMap { $0 }
                                    + [Self.formatGap(candidate.gapHours)]).joined(separator: " · "))
                }
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityHint(Text(String(localized: "collections.flight-candidate.details.hint", defaultValue: "Shows where you were before and after, and why this might be a flight.", comment: "VoiceOver hint on a possible flight row that opens its detail sheet.")))
            // `.borderless` is the one button style List treats as plain
            // inline content; explicit capsules give the answers their shape.
            let actionLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                : AnyLayout(HStackLayout(spacing: 10))
            actionLayout {
                Button {
                    confirm(candidate, target: target)
                } label: {
                    answerLabel(Label("Confirm Flight", systemImage: "checkmark"),
                                fill: AppTheme.cobaltFill, text: .white)
                }
                .buttonStyle(.borderless)
                .disabled(target == nil)
                .accessibilityLabel(route.map {
                    Text(String(localized: "collections.flight-candidate.confirm.accessibility", defaultValue: "Confirm flight from \($0.from) to \($0.to)", comment: "VoiceOver label for confirming a possible flight; the places or airport codes at each end."))
                } ?? Text("Confirm Flight"))

                Button {
                    dismiss(candidate, target: target)
                } label: {
                    answerLabel(Label("Dismiss", systemImage: "xmark"),
                                fill: AppTheme.inset, text: .primary)
                }
                .buttonStyle(.borderless)
                .disabled(target == nil || !record.canUsePortablePreferences)
                .accessibilityLabel(route.map {
                    Text(String(localized: "collections.flight-candidate.dismiss.accessibility", defaultValue: "Dismiss possible flight from \($0.from) to \($0.to)", comment: "VoiceOver label for dismissing a possible flight; the places or airport codes at each end."))
                } ?? Text("Dismiss"))
            }
        }
        .padding(.vertical, 4)
    }

    /// A 34 pt capsule inside a 44 pt tall hit area.
    private func answerLabel(_ label: Label<Text, Image>, fill: Color, text: Color) -> some View {
        label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .frame(minHeight: 34)
            .background(fill, in: .capsule)
            .foregroundStyle(text)
            .frame(minHeight: 44)
            .contentShape(.rect)
    }

    /// The ends VoiceOver names: place names when known, else codes.
    private static func spokenRoute(
        _ record: CollectionsAggregator.FlightRecord
    ) -> (from: String, to: String)? {
        guard let from = record.departureName ?? record.departureCode,
              let to = record.arrivalName ?? record.arrivalCode else { return nil }
        return (from, to)
    }

    // MARK: Answers

    /// The sheet's answers run here, after it closes, through the same
    /// writers as the rows.
    private func detailActions(_ presented: Detail) -> FlightDetailSheet.Actions {
        let target = presented.target
        var actions = FlightDetailSheet.Actions()
        actions.canAnswer = target != nil
        actions.canEditCorrections = target != nil && presented.subject.record.canUsePortablePreferences
        actions.openTrip = { tripID in
            tripAfterDetail = tripID
            detail = nil
        }
        switch presented.subject {
        case .candidate(let candidate):
            actions.confirm = { times, clearTimes, stops, route in
                detail = nil
                confirm(candidate, times: times, clearTimes: clearTimes, stops: stops, route: route,
                        target: target)
            }
            actions.dismissCandidate = {
                detail = nil
                dismiss(candidate, target: target)
            }
        case .flight(let flight):
            actions.notAFlight = {
                detail = nil
                markNotAFlight(flight, target: target)
            }
            actions.saveTimes = { times, refused in
                saveTimes(times, for: flight, target: target, refused: refused)
            }
            actions.saveStops = { codes, refused in
                saveStops(codes, for: flight, target: target, refused: refused)
            }
            actions.saveRoute = { route, refused in
                saveRoute(route, for: flight, target: target, refused: refused)
            }
        }
        return actions
    }

    /// Confirm: the candidate joins the log at once, as the record the
    /// question showed, wearing the ends, stops and times set with it.
    private func confirm(
        _ candidate: CollectionsAggregator.PossibleFlight, times: FlightTimeOverrides.Times? = nil,
        clearTimes: Bool = false, stops: [String]? = nil, route: FlightRouteOverrides.Route? = nil,
        target: FlightLogAuthority.Target?
    ) {
        let id = candidate.presentationID
        var record = candidate.record
        if let route {
            record = record.applyingRoute(route, resolve: Self.airport)
                .applyingStops(stops ?? record.stops?.map(\.code), resolve: Self.airport)
        } else if let stops {
            record = record.applyingStops(stops, resolve: Self.airport)
        }
        if times != nil || clearTimes { record = record.applyingUserTimes(times) }
        // Display only: its actions wait for the refreshed log.
        record.actionGuard = nil
        overlay.resolved.insert(id)
        overlay.confirmed[id] = record
        run(.confirm(times: times, clearTimes: clearTimes, stops: stops, route: route), target, row: id, revert: {
            overlay.resolved.remove(id)
            overlay.confirmed[id] = nil
        })
    }

    private func dismiss(_ candidate: CollectionsAggregator.PossibleFlight, target: FlightLogAuthority.Target?) {
        let id = candidate.presentationID
        overlay.resolved.insert(id)
        run(.dismiss, target, row: id, revert: { overlay.resolved.remove(id) }, committed: { result in
            if let receipt = result.receipt {
                pendingUndo = PendingUndo(kind: .dismissal, receipt: receipt, presentationID: id)
            }
        })
    }

    private func markNotAFlight(_ flight: CollectionsAggregator.FlightRecord, target: FlightLogAuthority.Target?) {
        let id = flight.presentationID
        overlay.removed.insert(id)
        run(.markNotFlight, target, row: id, revert: { overlay.removed.remove(id) }, committed: { result in
            if let receipt = result.receipt {
                pendingUndo = PendingUndo(kind: .notFlight, receipt: receipt, presentationID: id)
            }
        })
    }

    /// A flight's own times (nil: back to the estimate) and stops, shown
    /// in the row at once. A refusal goes to the sheet while it is open,
    /// so it keeps what the user entered.
    private func saveTimes(_ times: FlightTimeOverrides.Times?, for flight: CollectionsAggregator.FlightRecord,
                           target: FlightLogAuthority.Target?,
                           refused: @escaping @MainActor (FlightDetailSheet.Refusal) -> Void) {
        let id = flight.presentationID
        let edit = overlay.beginTimes(times, for: id)
        run(.setTimes(times), target, row: id, revert: {
            overlay.endTimes(edit, value: times, for: id, committed: false)
        }, refused: { why in
            if detail == nil { refusal = why } else { refused(why) }
        }, committed: { _ in
            overlay.endTimes(edit, value: times, for: id, committed: true)
        })
    }

    private func saveStops(_ codes: [String], for flight: CollectionsAggregator.FlightRecord,
                           target: FlightLogAuthority.Target?,
                           refused: @escaping @MainActor (FlightDetailSheet.Refusal) -> Void) {
        let id = flight.presentationID
        let edit = overlay.beginStops(codes, for: id)
        run(.setStops(codes), target, row: id, revert: {
            overlay.endStops(edit, value: codes, for: id, committed: false)
        }, refused: { why in
            if detail == nil { refusal = why } else { refused(why) }
        }, committed: { _ in
            overlay.endStops(edit, value: codes, for: id, committed: true)
        })
    }

    private func saveRoute(_ route: FlightRouteOverrides.Route, for flight: CollectionsAggregator.FlightRecord,
                           target: FlightLogAuthority.Target?,
                           refused: @escaping @MainActor (FlightDetailSheet.Refusal) -> Void) {
        let id = flight.presentationID
        let edit = overlay.beginRoute(route, for: id)
        run(.setRoute(route), target, row: id, revert: {
            overlay.endRoute(edit, value: route, for: id, committed: false)
        }, refused: { why in
            if detail == nil { refusal = why } else { refused(why) }
        }, committed: { _ in
            overlay.endRoute(edit, value: route, for: id, committed: true)
        })
    }

    private func performUndo(_ undo: PendingUndo) {
        guard pendingUndo == undo else { return }
        pendingUndo = nil
        let id = undo.presentationID
        func hide(_ hidden: Bool) {
            switch undo.kind {
            case .dismissal: if hidden { overlay.resolved.insert(id) } else { overlay.resolved.remove(id) }
            case .notFlight: if hidden { overlay.removed.insert(id) } else { overlay.removed.remove(id) }
            }
        }
        hide(false)
        run(.undo(undo.receipt), undo.receipt.target, row: id, revert: { hide(true) }, refused: { why in
            refusal = why
            // Offer it again, as the trip demotion's failed Undo does.
            pendingUndo = PendingUndo(kind: undo.kind, receipt: undo.receipt, presentationID: id)
        })
    }

    /// The one writer: `FlightLogAuthority` re-checks the row inside a
    /// pipeline unit. The overlay already shows the answer; a refused or
    /// failed write puts the row back (`revert`) and says why (`refused`,
    /// by default the log's alert). After a wipe it only puts the row back.
    /// The next Stats refresh starts without the debounce.
    private func run(
        _ action: FlightLogAuthority.Action, _ target: FlightLogAuthority.Target?, row id: PresentationID,
        revert: @escaping @MainActor () -> Void,
        refused: (@MainActor (FlightDetailSheet.Refusal) -> Void)? = nil,
        committed: @escaping @MainActor (FlightLogAuthority.Result) -> Void = { _ in }
    ) {
        let report: @MainActor (FlightDetailSheet.Refusal) -> Void = refused ?? { refusal = $0 }
        guard let target else {
            revert()
            report(.failed)
            return
        }
        refresh.expedite()
        let previous = actionChains[id]
        actionChains[id] = Task {
            await previous?.value
            // A correction checks the values the previous one wrote.
            var latest = target
            switch action {
            case .setTimes, .setStops, .setRoute: latest = overlay.targets[id] ?? target
            default: break
            }
            let result = await PipelineGate.shared.runReturning(touching: [.stay]) { [latest] in
                await Self.apply(action, target: latest)
            }
            // A wipe revoked this history: the row goes back, with neither
            // an error nor an Undo.
            guard latest.epoch == FlightLogAuthority.currentEpoch else {
                revert()
                return
            }
            if result.succeeded {
                if let advanced = result.updatedTarget { overlay.targets[id] = advanced }
                committed(result)
            } else {
                revert()
                report(result.status == .rejected ? .changed : .failed)
            }
        }
    }

    @MainActor
    private static func apply(_ action: FlightLogAuthority.Action,
                              target: FlightLogAuthority.Target) -> FlightLogAuthority.Result {
        FlightLogAuthority.apply(action, target: target, context: AppDelegate.modelContainer.mainContext)
    }

    private nonisolated static func airport(_ code: String) -> AirportRecord? {
        AirportDetector.shared.airport(code: code)
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

    // MARK: Rows

    /// A flight row opens its detail sheet. Edit Times is a leading swipe
    /// action, Not a Flight a trailing one, and both are in its context
    /// menu with its trip. `year` is its section's.
    @ViewBuilder
    private func flightEntry(_ flight: CollectionsAggregator.FlightRecord, inYear year: Int) -> some View {
        let notAFlight = String(localized: "collections.flight.not-a-flight", defaultValue: "Not a Flight", comment: "Flight Log action that removes a flight the user says was not a flight.")
        let editTimes = String(localized: "collections.flight.edit-times", defaultValue: "Edit Times", comment: "Flight Log action that edits a flight's departure and arrival times.")
        let target = FlightLogAuthority.Target(record: flight)
        let canEditTimes = target != nil && flight.canUsePortablePreferences
        Button {
            detail = Detail(subject: .flight(flight))
        } label: {
            flightRow(flight, inYear: year)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 16))
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if canEditTimes {
                Button {
                    detail = Detail(subject: .flight(flight), editTimes: true)
                } label: {
                    Label(editTimes, systemImage: "clock")
                }
                .tint(AppTheme.accent)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if target != nil {
                Button {
                    markNotAFlight(flight, target: target)
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
                    Label("Open Trip", systemImage: "suitcase")
                }
            }
            if canEditTimes {
                Button {
                    detail = Detail(subject: .flight(flight), editTimes: true)
                } label: {
                    Label(editTimes, systemImage: "clock")
                }
            }
            if target != nil {
                Button {
                    markNotAFlight(flight, target: target)
                } label: {
                    Label(notAFlight, systemImage: TransitMode.notFlight.systemImage)
                }
            }
        }
    }

    /// The Trips list's row grammar: the ends' flags lead, the
    /// destination's in front.
    @ViewBuilder
    private func flightRow(_ flight: CollectionsAggregator.FlightRecord, inYear year: Int) -> some View {
        TripLeadRow(codes: Self.flagCodes(flight)) {
            HStack(spacing: 6) {
                Text(flight.routeLabel)
                    .font(.subheadline.weight(.semibold))
                if flight.flewOvernight {
                    Image(systemName: "moon.fill")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.accent)
                        .accessibilityLabel("Overnight flight")
                }
                Spacer()
                Text(Self.flightDateText(flight, inYear: year))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            if let places = flight.placeRouteLabel {
                Text(places)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            if let measures = Self.distanceAndDuration(
                km: flight.flownKm, hours: flight.flightHours,
                estimated: flight.userTimes == nil) {
                Text(verbatim: measures)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .padding(.top, 2)
            }
        }
        // Whole-point rows leave no seam across the card's separators.
        .wholePointHeight()
    }

    /// The deck's countries: the destination, then the origin; one flag for
    /// a domestic flight, the neutral one for an end in no known country.
    static func flagCodes(_ flight: CollectionsAggregator.FlightRecord) -> [String] {
        let ends = [flight.arrivalISO, flight.departureISO].map { $0?.uppercased() ?? "" }
        let codes = ends[0] == ends[1] ? [ends[0]] : ends
        return codes == [""] ? [] : codes
    }

    // MARK: Text

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
    /// Ranges read as the Trips list's do ("1 to 2 Jul"), in the single
    /// date's day and month order. Under the year's section header (`year`)
    /// the dates leave out a year that is that one.
    static func flightDateText(_ record: CollectionsAggregator.FlightRecord, inYear year: Int? = nil,
                               locale: Locale = .autoupdatingCurrent) -> String {
        let zones = displayZones(record)
        let landed = record.userArrival ?? record.date
        guard let end = TravelDays.label(for: landed, zone: zones.arrival) else {
            let style = Date.FormatStyle(locale: locale).day().month(.abbreviated)
            let sameYear = Calendar(identifier: .gregorian).component(.year, from: landed) == year
            return landed.formatted(sameYear ? style : style.year())
        }
        // Day labels are civil dates at UTC midnight, so they format in UTC.
        var labels = Calendar.current
        labels.timeZone = TravelDays.labelCalendar.timeZone
        let start = (record.userDeparture ?? record.departureWindowStart)
            .flatMap { TravelDays.label(for: $0, zone: zones.departure) } ?? end
        let years = Set([start, end].map { TravelDays.labelCalendar.component(.year, from: $0) })
        let includeYear = year.map { years != [$0] } ?? true
        guard start <= end else {
            let style = Date.FormatStyle(locale: locale, calendar: labels, timeZone: labels.timeZone)
                .day().month(.abbreviated)
            let departure = start.formatted(includeYear ? style.year() : style)
            let arrival = end.formatted(includeYear ? style.year() : style)
            return String(
                localized: "collections.flight-date.reversed",
                defaultValue: "\(departure) → \(arrival)",
                comment: "Flight dates when the arrival's local date is earlier than the departure's (crossing the date line): departure date, then arrival date."
            )
        }
        return TripDisplayText.range(from: start, to: end, includeYear: includeYear,
                                     calendar: labels, locale: locale)
    }

    /// Flights by their year (`FlightLogProjection.year`), newest year
    /// first, each keeping the log's order.
    struct YearSection: Identifiable {
        let year: Int
        var flights: [CollectionsAggregator.FlightRecord]
        var id: Int { year }
    }

    static func yearSections(_ flights: [CollectionsAggregator.FlightRecord]) -> [YearSection] {
        var sections: [YearSection] = []
        var indexByYear: [Int: Int] = [:]
        for flight in flights {
            let year = FlightLogProjection.year(of: flight) ?? 0
            if let index = indexByYear[year] {
                sections[index].flights.append(flight)
            } else {
                indexByYear[year] = sections.count
                sections.append(YearSection(year: year, flights: [flight]))
            }
        }
        return sections.sorted { $0.year > $1.year }
    }

    /// "1.846 km · ≈ 2h 52m" (the user's own times without the ≈),
    /// leaving out a distance or duration the data cannot give; nil when
    /// neither is known.
    static func distanceAndDuration(km: Double, hours: Double, estimated: Bool) -> String? {
        var parts: [String] = []
        if km.isFinite, km > 0 { parts.append(UnitsFormatter.formatDistance(kilometers: km)) }
        if hours.isFinite, hours > 0 { parts.append((estimated ? "≈ " : "") + formatHours(hours)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func formatHours(_ hours: Double) -> String {
        Duration.seconds(hours * 60 * 60).formatted(.units(
            allowed: [.hours, .minutes], width: .narrow, maximumUnitCount: 2,
            fractionalPart: .hide(rounded: .toNearestOrAwayFromZero)
        ))
    }
}

extension FlightLogView {
    /// Places, codes, airport names and cities (stops included) as names;
    /// the ends' countries by every alias, as the Airports list searches.
    nonisolated static func searchIndex(
        _ flights: [CollectionsAggregator.FlightRecord],
        languageTag: String
    ) -> ListSearchIndex<CollectionsAggregator.FlightRecord> {
        var aliasesByISO: [String: [String]] = [:]
        return ListSearchIndex(entries: flights, languageTag: languageTag) { flight in
            let stops = flight.stops ?? []
            var names: [String?] = [flight.departurePlace, flight.arrivalPlace,
                                    flight.departureCode, flight.arrivalCode,
                                    flight.departureAirportName, flight.arrivalAirportName]
            for code in [flight.departureCode, flight.arrivalCode].compactMap({ $0 }) {
                names.append(AirportDetector.shared.airport(code: code)?.city)
            }
            for stop in stops {
                names += [stop.code, stop.name, stop.city]
            }
            var countries: [String] = []
            var codes: Set<String> = []
            let isos = [flight.departureISO, flight.arrivalISO] + stops.map(\.isoCountryCode)
            for iso in isos.compactMap({ $0?.uppercased() }) where !iso.isEmpty && codes.insert(iso).inserted {
                let aliases = aliasesByISO[iso]
                    ?? TripSearch.countryAliases(for: [iso], languageTag: languageTag)
                aliasesByISO[iso] = aliases
                countries += aliases
            }
            return (names.compactMap { $0 }, countries, codes)
        }
    }
}

/// The Flight Log summary's ground: the Passport cover's cobalt field and
/// corner glow, with faint flight arcs in its top trailing corner.
private struct FlightLogSummaryField: View {
    var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(
                stops: [
                    .init(color: AppTheme.field, location: 0),
                    .init(color: AppTheme.fieldMid, location: 0.46),
                    .init(color: AppTheme.fieldDeep, location: 1),
                ],
                startPoint: UnitPoint(x: 0.31, y: 0),
                endPoint: UnitPoint(x: 0.69, y: 1)
            )
            EllipticalGradient(
                colors: [AppTheme.coverGlow.opacity(0.9), AppTheme.coverGlow.opacity(0)],
                center: .topTrailing,
                startRadiusFraction: 0,
                endRadiusFraction: 0.62
            )
            Canvas { context, _ in
                var arcs = Path()
                arcs.move(to: CGPoint(x: 10, y: 150))
                arcs.addCurve(to: CGPoint(x: 230, y: 30), control1: CGPoint(x: 60, y: 40), control2: CGPoint(x: 160, y: 20))
                arcs.move(to: CGPoint(x: 40, y: 160))
                arcs.addCurve(to: CGPoint(x: 230, y: 70), control1: CGPoint(x: 90, y: 70), control2: CGPoint(x: 170, y: 60))
                arcs.move(to: CGPoint(x: -10, y: 120))
                arcs.addCurve(to: CGPoint(x: 230, y: -6), control1: CGPoint(x: 70, y: -10), control2: CGPoint(x: 170, y: -20))
                context.stroke(arcs, with: .color(.white.opacity(0.1)), lineWidth: 1)
                context.fill(Path(ellipseIn: CGRect(x: 135.8, y: 31.8, width: 4.4, height: 4.4)),
                             with: .color(.white.opacity(0.28)))
            }
            .frame(width: 210, height: 150)
        }
        .accessibilityHidden(true)
    }
}

/// The Flight Log's answers before a refreshed log carries them. Each one
/// shows at once and goes when an accepted snapshot agrees with it, so a
/// refresh that started before the answer never undoes it on screen.
struct FlightLogOverlay {
    typealias ID = CollectionsAggregator.FlightRecord.PresentationIdentity

    /// Candidates confirmed or dismissed.
    var resolved: Set<ID> = []
    /// The records confirmed candidates join the log as.
    var confirmed: [ID: CollectionsAggregator.FlightRecord] = [:]
    /// Flights marked Not a Flight.
    var removed: Set<ID> = []
    /// Times saved (nil: back to the estimate), stops (empty: none) and
    /// ends (empty: the detected ones).
    var times: [ID: FlightTimeOverrides.Times?] = [:]
    var stops: [ID: [String]] = [:]
    var routes: [ID: FlightRouteOverrides.Route] = [:]
    /// The write authority a committed correction advanced to.
    var targets: [ID: FlightLogAuthority.Target] = [:]
    /// Each row's newest queued times and stops edit, and the last value
    /// one committed: a refused edit falls back to that (or the log's own
    /// value), never to an earlier edit that was never saved.
    private var newestTimesEdit: [ID: UUID] = [:]
    private var newestStopsEdit: [ID: UUID] = [:]
    private var newestRouteEdit: [ID: UUID] = [:]
    private var committedTimes: [ID: FlightTimeOverrides.Times?] = [:]
    private var committedStops: [ID: [String]] = [:]
    private var committedRoutes: [ID: FlightRouteOverrides.Route] = [:]

    mutating func beginTimes(_ value: FlightTimeOverrides.Times?, for id: ID) -> UUID {
        let edit = UUID()
        times[id] = .some(value)
        newestTimesEdit[id] = edit
        return edit
    }

    mutating func endTimes(_ edit: UUID, value: FlightTimeOverrides.Times?, for id: ID, committed: Bool) {
        if committed { committedTimes[id] = .some(value) }
        guard newestTimesEdit[id] == edit else { return }
        newestTimesEdit[id] = nil
        if !committed { times[id] = committedTimes[id] }
    }

    mutating func beginStops(_ value: [String], for id: ID) -> UUID {
        let edit = UUID()
        stops[id] = value
        newestStopsEdit[id] = edit
        return edit
    }

    mutating func endStops(_ edit: UUID, value: [String], for id: ID, committed: Bool) {
        if committed { committedStops[id] = value }
        guard newestStopsEdit[id] == edit else { return }
        newestStopsEdit[id] = nil
        if !committed { stops[id] = committedStops[id] }
    }

    mutating func beginRoute(_ value: FlightRouteOverrides.Route, for id: ID) -> UUID {
        let edit = UUID()
        routes[id] = value
        newestRouteEdit[id] = edit
        return edit
    }

    mutating func endRoute(_ edit: UUID, value: FlightRouteOverrides.Route, for id: ID, committed: Bool) {
        if committed { committedRoutes[id] = value }
        guard newestRouteEdit[id] == edit else { return }
        newestRouteEdit[id] = nil
        if !committed { routes[id] = committedRoutes[id] }
    }

    func candidates(_ all: [CollectionsAggregator.PossibleFlight]) -> [CollectionsAggregator.PossibleFlight] {
        resolved.isEmpty ? all : all.filter { !resolved.contains($0.presentationID) }
    }

    func flights(_ all: [CollectionsAggregator.FlightRecord]) -> [CollectionsAggregator.FlightRecord] {
        guard !(confirmed.isEmpty && removed.isEmpty && times.isEmpty && stops.isEmpty && routes.isEmpty)
        else { return all }
        let present = Set(all.map(\.presentationID))
        var result = all.filter { !removed.contains($0.presentationID) }
        let joining = confirmed.filter { !present.contains($0.key) }.values
        if !joining.isEmpty {
            result += joining
            result.sort { ($0.userArrival ?? $0.date) > ($1.userArrival ?? $1.date) }
        }
        return result.map { flight in
            var flight = flight
            let route = routes[flight.presentationID]
            if let route {
                flight = flight.applyingRoute(route) { AirportDetector.shared.airport(code: $0) }
            }
            // New ends can free or claim a stop's code: the stops apply again.
            if let codes = stops[flight.presentationID] ?? (route == nil ? nil : flight.stops?.map(\.code)) {
                flight = flight.applyingStops(codes) { AirportDetector.shared.airport(code: $0) }
            }
            if let edit = times[flight.presentationID] {
                flight = flight.applyingUserTimes(edit)
            }
            return flight
        }
    }

    mutating func reconcile(with collections: CollectionsAggregator.Collections) {
        let candidateIDs = Set(collections.possibleFlights.map(\.presentationID))
        let flights = Dictionary(collections.flights.map { ($0.presentationID, $0) },
                                 uniquingKeysWith: { first, _ in first })
        resolved = resolved.filter(candidateIDs.contains)
        confirmed = confirmed.filter { candidateIDs.contains($0.key) }
        removed = removed.filter { flights[$0] != nil }
        func timesDiffer(_ id: ID, _ edit: FlightTimeOverrides.Times?) -> Bool {
            flights[id].map { !Self.sameTimes($0.userTimes, edit) } ?? false
        }
        func stopsDiffer(_ id: ID, _ codes: [String]) -> Bool {
            flights[id].map { ($0.stops?.map(\.code) ?? []) != codes } ?? false
        }
        times = times.filter { timesDiffer($0.key, $0.value) }
        committedTimes = committedTimes.filter { timesDiffer($0.key, $0.value) }
        func routeDiffers(_ id: ID, _ route: FlightRouteOverrides.Route) -> Bool {
            flights[id].map { ($0.userRoute ?? FlightRouteOverrides.Route()) != route } ?? false
        }
        stops = stops.filter { stopsDiffer($0.key, $0.value) }
        committedStops = committedStops.filter { stopsDiffer($0.key, $0.value) }
        routes = routes.filter { routeDiffers($0.key, $0.value) }
        committedRoutes = committedRoutes.filter { routeDiffers($0.key, $0.value) }
        targets = targets.filter { id, target in
            flights[id].map { $0.annotationSnapshot != target.annotations } ?? false
        }
    }

    /// Saved times keep whole seconds.
    private static func sameTimes(_ lhs: FlightTimeOverrides.Times?, _ rhs: FlightTimeOverrides.Times?) -> Bool {
        func seconds(_ times: FlightTimeOverrides.Times?) -> [Double]? {
            times.map { [$0.departure.timeIntervalSince1970.rounded(), $0.arrival.timeIntervalSince1970.rounded()] }
        }
        return seconds(lhs) == seconds(rhs)
    }
}

// MARK: - Places

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
