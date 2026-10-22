//
//  FlightDetailSheet.swift
//  TravelLog
//
//  One flight or possible flight in full, opened from the Flight Log: where
//  the user was on either side, the window the data leaves between them,
//  the evidence in plain words and the arc on a map, with the log's answers,
//  the stops the user adds (`FlightStops`) and the flight-times editor
//  (`FlightTimeOverrides`). Renders the aggregate's record; the only reads
//  are the trips' names and the bundled airports.
//

import SwiftUI
import SwiftData

struct FlightDetailSheet: View {
    enum Subject {
        case candidate(CollectionsAggregator.PossibleFlight)
        case flight(CollectionsAggregator.FlightRecord)

        var record: CollectionsAggregator.FlightRecord {
            switch self {
            case .candidate(let candidate): candidate.record
            case .flight(let flight): flight
            }
        }
    }

    /// The Flight Log's writers; the sheet closes before the log runs one.
    struct Actions {
        /// A fresh physical-row witness is available for a mode decision.
        var canChangeMode = false
        /// Portable UUID preferences are safe for this current physical row.
        /// Also controls dismissal, which is stored in that preference ledger.
        var canEditCorrections = false
        /// Read live authority and busy state before changing local corrections;
        /// visual availability can lag a rapid second tap by one frame.
        var mayBeginCorrection: () -> Bool = { false }
        /// Confirm a candidate with separately accepted corrections.
        /// `clearTimes` distinguishes explicit removal from untouched nil;
        /// nil stops leave the saved connections untouched.
        var confirm: (FlightTimeOverrides.Times?, Bool, [String]?) -> Void = { _, _, _ in }
        var dismissCandidate: () -> Void = {}
        var notAFlight: () -> Void = {}
        /// A flight's own times; nil goes back to the derived ones.
        var saveTimes: (FlightTimeOverrides.Times?) -> Void = { _ in }
        /// A flight's recorded connections, in order; empty clears them.
        var saveStops: ([String]) -> Void = { _ in }
        var openTrip: (UUID) -> Void = { _ in }
    }

    let subject: Subject
    /// The Airports list's codes, suggested as stops before the hubs.
    let visitedAirportCodes: [String]
    let actions: Actions

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The flight's times as saved, or a candidate's waiting for Confirm.
    @State private var times: FlightTimeOverrides.Times?
    @State private var didClearTimes = false
    @State private var isEditingTimes: Bool
    @State private var draftDeparture: Date
    @State private var draftArrival: Date
    @State private var tripNames: [TripName] = []
    /// The flight's stops as saved, or a candidate's waiting for Confirm.
    @State private var stopCodes: [String]
    @State private var isAddingStop = false
    @State private var stopQuery = ""
    /// Built when the stop picker first opens.
    @State private var stopSearchIndex: FlightStops.SearchIndex?

    init(subject: Subject, editTimes: Bool = false, visitedAirportCodes: [String] = [],
         actions: Actions) {
        self.subject = subject
        self.visitedAirportCodes = visitedAirportCodes
        self.actions = actions
        let record = subject.record
        let saved = record.userTimes.flatMap {
            FlightTimeOverrides.fits($0, windowStart: record.departureWindowStart, windowEnd: record.date,
                                     earliestDeparture: record.departureLastObservedAt)
                ? $0 : nil
        }
        let draft = saved ?? FlightTimeOverrides.suggested(
            windowStart: record.departureWindowStart, windowEnd: record.date,
            estimatedHours: record.journeyEstimatedHours,
            earliestDeparture: record.departureLastObservedAt)
        _times = State(initialValue: saved)
        _isEditingTimes = State(initialValue: editTimes && actions.canEditCorrections)
        _draftDeparture = State(initialValue: draft.departure)
        _draftArrival = State(initialValue: draft.arrival)
        _stopCodes = State(initialValue: record.stops?.map(\.code) ?? [])
    }

    private var isCandidate: Bool {
        if case .candidate = subject { return true }
        return false
    }

    /// The record as the sheet shows it: wearing the stops and times saved
    /// or set here.
    private var record: CollectionsAggregator.FlightRecord {
        subject.record.applyingStops(stopCodes, resolve: Self.airport).applyingUserTimes(times)
    }

    private nonisolated static func airport(_ code: String) -> AirportRecord? {
        AirportDetector.shared.airport(code: code)
    }

    /// A candidate's stops go with Confirm only when the user changed them.
    private var changedStops: [String]? {
        stopCodes == (subject.record.stops?.map(\.code) ?? []) ? nil : stopCodes
    }

    private var zones: (departure: TimeZone, arrival: TimeZone) {
        let fallback = TimeZone(secondsFromGMT: 0)!
        return (StayTimeZone.resolve(record.departureTimeZoneIdentifier, fallback: fallback),
                StayTimeZone.resolve(record.arrivalTimeZoneIdentifier, fallback: fallback))
    }

    private var usesUTCFallback: Bool {
        [record.departureTimeZoneIdentifier, record.arrivalTimeZoneIdentifier].contains { identifier in
            identifier.flatMap { TimeZone(identifier: $0) } == nil
        }
    }

    private var draft: FlightTimeOverrides.Times {
        FlightTimeOverrides.Times(departure: draftDeparture, arrival: draftArrival)
    }

    private var allowedRange: ClosedRange<Date> {
        FlightTimeOverrides.allowedRange(windowStart: subject.record.departureWindowStart,
                                         windowEnd: subject.record.date,
                                         earliestDeparture: subject.record.departureLastObservedAt)
    }

    private var draftProblem: String? {
        if let problem = Self.problem(with: draft) { return problem }
        guard FlightTimeOverrides.fits(draft, windowStart: subject.record.departureWindowStart,
                                       windowEnd: subject.record.date,
                                       earliestDeparture: subject.record.departureLastObservedAt) else {
            return String(localized: "flight-log.detail.times.outside-window", defaultValue: "Keep both times within the available observation window.", comment: "Flight-time editor validation when a draft falls outside the allowed observation window and its existing slack.")
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header(record)
                }
                if record.flightLogDepartureLatitude != nil,
                   record.flightLogDepartureLongitude != nil,
                   record.flightLogArrivalLatitude != nil,
                   record.flightLogArrivalLongitude != nil {
                    Section {
                        FlightRouteMap(records: [record], isCandidate: isCandidate)
                            .frame(height: 190)
                            .listRowInsets(EdgeInsets())
                            .id(record.stops?.map(\.code) ?? [])
                    } footer: {
                        Text(String(localized: "flight-log.detail.map.caption", defaultValue: "Approximate route, not an aircraft track.", comment: "Caption for the offline flight-detail schematic, which joins recorded places and user-added connections rather than measured aircraft positions."))
                    }
                }
                Section {
                    journey(record)
                } header: {
                    Text(String(localized: "flight-log.detail.observations", defaultValue: "Location History", comment: "Flight detail section showing the observations on either side of a possible or recorded flight."))
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(Self.sourceExplanation(record))
                        if usesUTCFallback {
                            Text(String(localized: "flight-log.detail.times.utc-fallback", defaultValue: "Times use UTC where the original time zone is unavailable.", comment: "Flight detail note when either historical endpoint lacks a recognized stored time zone; the current device time zone never changes the displayed history."))
                        }
                    }
                }
                Section {
                    clues(record)
                } header: {
                    Text(isCandidate
                         ? String(localized: "collections.flight-detail.clues.candidate", defaultValue: "Why It Looks Like a Flight", comment: "Flight detail section header listing the evidence for a possible flight.")
                         : String(localized: "flight-log.detail.evidence", defaultValue: "Why It Was Recorded", comment: "Flight detail section header explaining the evidence behind a recorded flight without asserting verified service details."))
                } footer: {
                    if isCandidate {
                        Text(String(localized: "flight-log.detail.confirmation-boundary", defaultValue: "Confirming says that you flew. It does not verify the airports, dates or connections.", comment: "Clarifies the limited meaning of confirming a possible flight."))
                    }
                }
                routeAndTimingSection(record)
                if case .flight = subject {
                    flightActions(record)
                }
            }
            .navigationTitle(isCandidate
                             ? String(localized: "collections.flight-detail.title.candidate", defaultValue: "Possible Flight", comment: "Navigation title of the detail sheet for a possible flight.")
                             : String(localized: "collections.flight-detail.title.flight", defaultValue: "Flight", comment: "Navigation title of the detail sheet for a confirmed flight."))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isCandidate, actions.canChangeMode || actions.canEditCorrections { answerBar }
            }
            .task {
                tripNames = Self.readTripNames(
                    [record.departureTripID, record.arrivalTripID, record.tripID].compactMap { $0 })
            }
        }
    }

    // MARK: Header

    @ViewBuilder
    private func header(_ record: CollectionsAggregator.FlightRecord) -> some View {
        let ends = Self.ends(record)
        VStack(alignment: .leading, spacing: 6) {
            Text(isCandidate
                 ? String(localized: "collections.flight-detail.question", defaultValue: "Did you fly from \(ends.from) to \(ends.to)?", comment: "Flight detail question for a possible flight: the places (or airport codes) before and after it.")
                 : FlightLogProjection.primaryRoute(record))
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(String(localized: "flight-log.detail.history-dates", defaultValue: "History dates: \(FlightLogProjection.dateText(record))", comment: "Flight detail date label for the recorded-history boundaries, which may include inferred stay extensions rather than exact location fixes or verified flight dates."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(Self.sourceText(record))
                .font(.caption)
                .foregroundStyle(.secondary)
            if !tripNames.isEmpty {
                // The trips on either side: which journey this leg belongs to.
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tripNames) { trip in
                        Button {
                            actions.openTrip(trip.id)
                        } label: {
                            AppChip(label: Text(trip.name), systemImage: "suitcase", small: true)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityHint(Text("Open Trip"))
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Journey

    private enum Side { case departure, arrival }

    @ViewBuilder
    private func journey(_ record: CollectionsAggregator.FlightRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            stop(.departure, record)
            leg(record)
            stop(.arrival, record)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func stop(_ side: Side, _ record: CollectionsAggregator.FlightRecord) -> some View {
        let isDeparture = side == .departure
        let place = isDeparture
            ? record.departurePlace ?? record.departureCode
            : record.arrivalPlace ?? record.arrivalCode
        let code = isDeparture ? record.departureCode : record.arrivalCode
        let airport = isDeparture ? record.departureAirportName : record.arrivalAirportName
        let resolution = isDeparture ? record.departureAirportResolution : record.arrivalAirportResolution
        let iso = isDeparture ? record.departureISO : record.arrivalISO
        let isHome = (isDeparture ? record.departureIsHome : record.arrivalIsHome) == true
        let zone = isDeparture ? zones.departure : zones.arrival
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(AppTheme.routeCasing)
                .overlay(Circle().strokeBorder(AppTheme.routeLine, lineWidth: 2.4))
                .frame(width: 14, height: 14)
                .padding(.top, 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(place ?? "?")
                        .font(.headline)
                    FlagView(iso: iso, size: .small)
                    if isHome {
                        Image(systemName: "house.fill")
                            .font(.caption)
                            .foregroundStyle(AppTheme.accent)
                            .accessibilityLabel(Text(String(localized: "collections.flight-detail.home", defaultValue: "Home", comment: "VoiceOver label for the house glyph beside a flight's end that is the user's home.")))
                    }
                }
                if let code {
                    Text(Self.airportText(code: code, name: airport, resolution: resolution))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if isDeparture {
                    if let boundary = Self.lastSeen(record) {
                        Text(String(localized: "flight-log.detail.departure-boundary", defaultValue: "Departure history ends \(Self.timeText(boundary, zone: zone))", comment: "Flight detail departure-history boundary, which can be a clustered stay end extending beyond the last recorded fix, not a measured takeoff or exact observation time."))
                            .font(.subheadline)
                    } else {
                        Text(String(localized: "flight-log.detail.departure-observation-missing", defaultValue: "Departure observation unavailable", comment: "Flight detail when no observation brackets the start of a flight journey."))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(String(localized: "flight-log.detail.arrival-boundary", defaultValue: "Arrival history begins \(Self.timeText(record.date, zone: zone))", comment: "Flight detail arrival-history boundary, shown in the recorded location-history time zone or UTC fallback, rather than a verified landing time."))
                        .font(.subheadline)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func leg(_ record: CollectionsAggregator.FlightRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // The rail between the two stations, as long as this leg's lines.
            Rectangle()
                .fill(AppTheme.routeLine.opacity(0.5))
                .frame(width: 2)
                .frame(width: 14)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                if let gap = Self.gapSeconds(record) {
                    Label {
                        Text(String(localized: "flight-log.detail.history-gap", defaultValue: "\(Self.durationText(gap)) gap in history", comment: "Flight detail duration between recorded-history boundaries, which may include an inferred stay extension; not measured flying time or an exact fix-to-fix interval."))
                    } icon: {
                        Image(systemName: "airplane")
                            .foregroundStyle(AppTheme.accent)
                    }
                    .font(.subheadline.weight(.medium))
                    .labelStyle(.titleAndIcon)
                }
                if let kilometers = FlightLogProjection.estimatedDistanceKm(for: record) {
                    let distance = UnitsFormatter.formatDistance(kilometers: kilometers)
                    Text(String(localized: "flight-log.detail.approximate-distance", defaultValue: "Approximate route distance: \(distance)", comment: "Flight detail distance along the approximate route, including user-supplied connections when available."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.vertical, 10)
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    // MARK: Clues

    @ViewBuilder
    private func clues(_ record: CollectionsAggregator.FlightRecord) -> some View {
        if case .candidate(let candidate) = subject, let evidence = candidate.evidence {
            Label {
                Text(Self.evidenceSentence(evidence, record: record))
            } icon: {
                Image(systemName: Self.evidenceSymbol(evidence))
                    .foregroundStyle(AppTheme.accent)
            }
        }
        if let assessment = record.assessment {
            Label {
                Text(Self.speedVerdict(FlightJudge.pace(assessment)))
            } icon: {
                Image(systemName: "speedometer")
                    .foregroundStyle(AppTheme.accent)
            }
        }
        if record.assessment == nil, !isCandidate {
            Label {
                Text(String(localized: "flight-log.detail.earlier-record", defaultValue: "Recorded as a flight in your travel history. Detailed detection evidence is unavailable.", comment: "Flight detail explanation for an older snapshot or stored flight without its assessment; does not assert whether it was detected or user-confirmed."))
            } icon: {
                Image(systemName: "info.circle")
                    .foregroundStyle(AppTheme.accent)
            }
        }
    }

    // MARK: Route and timing

    @ViewBuilder
    private func routeAndTimingSection(_ record: CollectionsAggregator.FlightRecord) -> some View {
        Section {
            routeRows(record)
            timingRows(record)
        } header: {
            Text(String(localized: "collections.flight-route-timing.header", defaultValue: "Route and Timing", comment: "Flight detail section header for the flight's stops, departure, arrival and duration."))
        } footer: {
            Text(routeAndTimingFooter(record))
        }
    }

    // MARK: Stops

    private var addStopTitle: String {
        String(localized: "collections.flight-stops.add", defaultValue: "Add a Stop", comment: "Flight detail button that adds a connecting airport to a flight the data saw as nonstop.")
    }

    @ViewBuilder
    private func routeRows(_ record: CollectionsAggregator.FlightRecord) -> some View {
        let stops = record.stops ?? []
        if stops.isEmpty {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(spacing: 12))
            layout {
                Label {
                    Text(String(localized: "flight-log.detail.connections.not-recorded", defaultValue: "No connections recorded", comment: "Flight detail when no connecting airport was supplied; does not assert a nonstop flight."))
                } icon: {
                    Image(systemName: "airplane")
                        .foregroundStyle(AppTheme.accent)
                }
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                if !isAddingStop, actions.canEditCorrections {
                    Button(addStopTitle) {
                        beginAddingStop()
                    }
                    .buttonStyle(.borderless)
                }
            }
        } else {
            Text(String(localized: "flight-log.detail.connections.supplied", defaultValue: "Connections you added", comment: "Flight detail heading identifying connecting airports as user-supplied."))
                .font(.subheadline.weight(.semibold))
            ForEach(Array(stops.enumerated()), id: \.offset) { index, stop in
                stopRow(stop, at: index)
            }
            if stops.count < FlightStops.maximumStops, !isAddingStop, actions.canEditCorrections {
                Button {
                    beginAddingStop()
                } label: {
                    Label(addStopTitle, systemImage: "plus")
                }
            }
        }
        if isAddingStop, actions.canEditCorrections {
            stopPicker(record)
        }
    }

    @ViewBuilder
    private func stopRow(_ stop: CollectionsAggregator.FlightRecord.Stop, at index: Int) -> some View {
        let place = stop.city ?? stop.code
        HStack(spacing: 12) {
            // A plain station, smaller than the journey's ends.
            Circle()
                .fill(AppTheme.routeCasing)
                .overlay(Circle().strokeBorder(AppTheme.routeLine, lineWidth: 2))
                .frame(width: 10, height: 10)
                .frame(width: 14)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(place)
                        .font(.subheadline.weight(.semibold))
                    FlagView(iso: stop.isoCountryCode, size: .small)
                }
                Text(stop.name.map { String(localized: "collections.flight-detail.airport", defaultValue: "\(stop.code) · \($0)", comment: "Flight detail line naming an airport: its code, then its name.") } ?? stop.code)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if actions.canEditCorrections {
                Button {
                    removeStop(at: index)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(String(localized: "collections.flight-stops.remove.accessibility", defaultValue: "Remove the stop in \(place), \(stop.code)", comment: "VoiceOver label for the button that removes a connecting airport from a flight: the airport's city, then its code.")))
            }
        }
    }

    /// Suggestions on the way as chips, then a search over every scheduled
    /// airport. Without the ends' points, the search alone.
    @ViewBuilder
    private func stopPicker(_ record: CollectionsAggregator.FlightRecord) -> some View {
        let suggestions = stopSuggestions(record)
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "collections.flight-stops.suggested", defaultValue: "On the way", comment: "Caption above suggested connecting airports that lie roughly between a flight's two ends."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(suggestions, id: \.code) { airport in
                            let place = airport.city ?? airport.name ?? airport.code
                            Button {
                                addStop(airport.code)
                            } label: {
                                AppChip(label: Text(verbatim: "\(place) · \(airport.code)"))
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text(addStopLabel(place: place, code: airport.code)))
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            .padding(.vertical, 4)
        }
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(String(localized: "collections.flight-stops.search.prompt", defaultValue: "Airport code, name or city", comment: "Placeholder of the search field for a flight's connecting airport."), text: $stopQuery)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
        }
        let query = stopQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty, let index = stopSearchIndex {
            let excluded = excludedStopCodes(record)
            let results = FlightStops.search(query, in: index).filter { !excluded.contains($0.code) }
            if results.isEmpty {
                Text(String(localized: "collections.flight-stops.search.empty", defaultValue: "No airports match.", comment: "Shown under the connecting-airport search when nothing matches."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(results, id: \.code) { airport in
                    let place = airport.city ?? airport.name ?? airport.code
                    Button {
                        addStop(airport.code)
                    } label: {
                        HStack(spacing: 12) {
                            Text(verbatim: airport.code)
                                .font(.subheadline.weight(.semibold))
                                .monospaced()
                                .foregroundStyle(.primary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(place)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                if let name = airport.name, name != place {
                                    Text(name)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 8)
                            FlagView(iso: airport.iso, size: .small)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(addStopLabel(place: place, code: airport.code)))
                    .accessibilityAddTraits(.isButton)
                }
            }
        }
        Button("Cancel", role: .cancel) {
            endAddingStop()
        }
    }

    private func addStopLabel(place: String, code: String) -> String {
        String(localized: "collections.flight-stops.add.accessibility", defaultValue: "Add a stop in \(place), \(code)", comment: "VoiceOver label for a suggested or found connecting airport: its city, then its code.")
    }

    /// The codes already on the route: its ends and its stops.
    private func excludedStopCodes(_ record: CollectionsAggregator.FlightRecord) -> Set<String> {
        Set([record.departureCode, record.arrivalCode].compactMap { $0 } + stopCodes)
    }

    /// Airports on the way over what is left of the route: from the last
    /// stop (else the departure) to the arrival.
    private func stopSuggestions(_ record: CollectionsAggregator.FlightRecord) -> [AirportRecord] {
        let last = record.stops?.last
        guard let fromLatitude = last?.latitude ?? record.departureLatitude,
              let fromLongitude = last?.longitude ?? record.departureLongitude,
              let toLatitude = record.arrivalLatitude, let toLongitude = record.arrivalLongitude
        else { return [] }
        return FlightStops.suggestions(
            fromLatitude: fromLatitude, fromLongitude: fromLongitude,
            toLatitude: toLatitude, toLongitude: toLongitude,
            excluding: excludedStopCodes(record), visited: visitedAirportCodes,
            resolve: Self.airport)
    }

    private func beginAddingStop() {
        guard actions.canEditCorrections else { return }
        if stopSearchIndex == nil {
            stopSearchIndex = FlightStops.SearchIndex(AirportDetector.shared.allAirports)
        }
        isAddingStop = true
    }

    private func endAddingStop() {
        isAddingStop = false
        stopQuery = ""
    }

    private func addStop(_ code: String) {
        guard actions.canEditCorrections, stopCodes.count < FlightStops.maximumStops,
              !stopCodes.contains(code), actions.mayBeginCorrection() else { return }
        stopCodes.append(code)
        endAddingStop()
        if !isCandidate { actions.saveStops(stopCodes) }
    }

    private func removeStop(at index: Int) {
        guard actions.canEditCorrections, stopCodes.indices.contains(index),
              actions.mayBeginCorrection() else { return }
        stopCodes.remove(at: index)
        if !isCandidate { actions.saveStops(stopCodes) }
    }

    // MARK: Flight times

    @ViewBuilder
    private func timingRows(_ record: CollectionsAggregator.FlightRecord) -> some View {
        if isEditingTimes, actions.canEditCorrections {
            Text(String(localized: "flight-log.detail.times.draft", defaultValue: "Set the times you remember", comment: "Flight-time editor heading; its initial values are a draft, not detected departure and arrival times."))
                .font(.subheadline.weight(.semibold))
            DatePicker(selection: $draftDeparture, in: allowedRange, displayedComponents: [.date, .hourAndMinute]) {
                zoneLabel(String(localized: "collections.flight-times.departure", defaultValue: "Departure", comment: "Flight times label for when the flight took off."),
                          zone: zones.departure, at: draftDeparture)
            }
            .environment(\.timeZone, zones.departure)
            DatePicker(selection: $draftArrival, in: allowedRange, displayedComponents: [.date, .hourAndMinute]) {
                zoneLabel(String(localized: "collections.flight-times.arrival", defaultValue: "Arrival", comment: "Flight times label for when the flight landed."),
                          zone: zones.arrival, at: draftArrival)
            }
            .environment(\.timeZone, zones.arrival)
            if let problem = draftProblem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.attention)
            } else {
                timeRow(journeyTimeTitle, value: FlightLogView.formatHours(draft.duration / 3600))
            }
            Button {
                saveDraft()
            } label: {
                Text(isCandidate
                     ? String(localized: "collections.flight-times.use", defaultValue: "Use These Times", comment: "Button that keeps the times set for a possible flight until the user confirms it.")
                     : String(localized: "collections.flight-times.save", defaultValue: "Save Times", comment: "Button that saves the times the user set for a flight."))
                    .fontWeight(.semibold)
            }
            .disabled(draftProblem != nil)
            Button("Cancel", role: .cancel) {
                isEditingTimes = false
            }
        } else if let times = record.userTimes {
            Text(String(localized: "flight-log.detail.times.supplied", defaultValue: "Saved times", comment: "Flight detail heading for saved departure and arrival times. Older saved values may have originated from generated drafts, so this heading does not assert human provenance."))
                .font(.subheadline.weight(.semibold))
            timeRow(String(localized: "collections.flight-times.departure", defaultValue: "Departure", comment: "Flight times label for when the flight took off."),
                    value: Self.timeText(times.departure, zone: zones.departure, includingYear: true))
            timeRow(String(localized: "collections.flight-times.arrival", defaultValue: "Arrival", comment: "Flight times label for when the flight landed."),
                    value: Self.timeText(times.arrival, zone: zones.arrival, includingYear: true))
            timeRow(journeyTimeTitle, value: FlightLogView.formatHours(times.duration / 3600))
            editTimesButton(record)
            if actions.canEditCorrections {
                Button {
                    guard actions.canEditCorrections, actions.mayBeginCorrection() else { return }
                    self.times = nil
                    didClearTimes = true
                    if !isCandidate { actions.saveTimes(nil) }
                } label: {
                    Label(String(localized: "flight-log.detail.times.clear", defaultValue: "Remove Saved Times", comment: "Button clearing saved flight times while preserving the observation window."),
                          systemImage: "arrow.uturn.backward")
                }
            }
        } else {
            if let kilometers = FlightLogProjection.estimatedDistanceKm(for: record) {
                let estimate = CollectionsAggregator.estimatedHours(distanceKm: kilometers)
                    + Double(record.stops?.count ?? 0)
                        * (CollectionsAggregator.estimatedHours(distanceKm: 0) + FlightStops.connectionHours)
                timeRow(String(localized: "flight-log.detail.duration.estimated", defaultValue: "Estimated duration", comment: "Flight detail duration calculated from route distance, never a measured airborne duration."),
                        value: "≈ \(FlightLogView.formatHours(estimate))")
            }
            editTimesButton(record)
        }
    }

    private var journeyTimeTitle: String {
        String(localized: "flight-log.detail.duration.journey", defaultValue: "Journey time", comment: "Elapsed time between user-supplied departure and arrival, which may include connections or airport time.")
    }

    @ViewBuilder
    private func editTimesButton(_ record: CollectionsAggregator.FlightRecord) -> some View {
        if actions.canEditCorrections {
            Button {
                openTimesEditor(record)
            } label: {
                Label(times == nil
                      ? String(localized: "collections.flight-times.set", defaultValue: "Set Times", comment: "Button that opens the editor for a flight's departure and arrival times.")
                      : String(localized: "collections.flight.edit-times", defaultValue: "Edit Times", comment: "Flight Log action that edits a flight's departure and arrival times."),
                      systemImage: "clock")
            }
        }
    }

    /// The editor starts at the times set, else landing at the first fix
    /// at the destination (`FlightTimeOverrides.suggested`).
    private func openTimesEditor(_ record: CollectionsAggregator.FlightRecord) {
        guard actions.canEditCorrections else { return }
        let start = times ?? FlightTimeOverrides.suggested(
            windowStart: subject.record.departureWindowStart, windowEnd: subject.record.date,
            estimatedHours: record.journeyEstimatedHours,
            earliestDeparture: subject.record.departureLastObservedAt)
        draftDeparture = start.departure
        draftArrival = start.arrival
        isEditingTimes = true
    }

    private func routeAndTimingFooter(_ record: CollectionsAggregator.FlightRecord) -> String {
        if isEditingTimes, actions.canEditCorrections {
            return String(localized: "flight-log.detail.times.editor-note", defaultValue: "Check the draft times before saving. Time zones follow your location history and may be approximate.", comment: "Flight-time editor footer: initial values may be generated estimates or previously supplied times, and stored location-history time zones are not verified airport schedule zones.")
        }
        if isCandidate, changedStops != nil || times != nil || didClearTimes {
            return String(localized: "flight-log.detail.corrections.on-confirm", defaultValue: "Changes to connections and saved times take effect when you confirm that you flew.", comment: "Footer explaining that a candidate's accepted connection/time edits or removals apply on confirmation only; an open, unaccepted time draft is never saved by confirming a flight.")
        }
        if record.userTimes != nil {
            return String(localized: "flight-log.detail.times.saved-note", defaultValue: "Journey time may include connections or airport time. Saved times are kept on this device and in backups; displayed time zones may be approximate.", comment: "Flight detail footer distinguishing saved journey duration from measured airborne time, with storage and timezone limitations. Older saved values do not establish human provenance.")
        }
        return String(localized: "flight-log.detail.route.note", defaultValue: "Duration is estimated from distance. Missing observations can hide flight dates and connections. Connections you add stay on this device and in backups.", comment: "Flight route and timing footer explaining estimates, incomplete observation windows and user-supplied connections.")
    }

    private func saveDraft() {
        let draft = draft
        guard actions.canEditCorrections, draftProblem == nil,
              actions.mayBeginCorrection() else { return }
        times = draft
        didClearTimes = false
        isEditingTimes = false
        if !isCandidate { actions.saveTimes(draft) }
    }

    @ViewBuilder
    private func zoneLabel(_ title: String, zone: TimeZone, at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
            Text(Self.zoneName(zone, at: date))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func timeRow(_ label: String, value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
    }

    // MARK: Actions

    @ViewBuilder
    private func flightActions(_ record: CollectionsAggregator.FlightRecord) -> some View {
        Section {
            if let tripID = record.tripID {
                Button {
                    actions.openTrip(tripID)
                } label: {
                    Label("Open Trip", systemImage: "suitcase")
                }
            }
            if actions.canChangeMode {
                Button {
                    actions.notAFlight()
                } label: {
                    Label(String(localized: "collections.flight.not-a-flight", defaultValue: "Not a Flight", comment: "Flight Log action that removes a flight the user says was not a flight."),
                          systemImage: TransitMode.notFlight.systemImage)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    /// The question's answers, always in reach under the context.
    private var answerBar: some View {
        VStack(spacing: 8) {
            if actions.canChangeMode {
                Button {
                    // Confirming the transport mode accepts no timing claim.
                    // Only Save/Use These Times can accept an editor draft.
                    actions.confirm(times, didClearTimes, changedStops)
                } label: {
                    Text(String(localized: "collections.flight-detail.answer.yes", defaultValue: "Yes, Confirm Flight", comment: "Answer to Did you fly from one place to another that adds the possible flight to the Flight Log."))
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            if actions.canEditCorrections {
                Button {
                    actions.dismissCandidate()
                } label: {
                    Text(String(localized: "collections.flight-detail.answer.no", defaultValue: "No, Dismiss", comment: "Answer to Did you fly from one place to another that dismisses the possible flight on this device."))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
    }

    // MARK: Text

    private enum HistorySource {
        case locations, photos, mixed, imported, unknown
    }

    /// Display provenance must not use DataSource.decode's legacy live
    /// fallback: a cached record without this metadata is simply unknown.
    private static func historySource(_ record: CollectionsAggregator.FlightRecord) -> HistorySource {
        guard record.departureSourceRaw != nil, record.arrivalSourceRaw != nil else { return .unknown }
        let raws = record.effectiveSourceRaws
        let sources = raws.compactMap(DataSource.init(rawValue:))
        guard !sources.isEmpty, sources.count == raws.count else { return .unknown }
        if sources.contains(.merged) { return .mixed }
        if sources.allSatisfy(\.isLiveObservation) { return .locations }
        if sources.allSatisfy({ $0 == .photoImport }) { return .photos }
        if Set(sources).count > 1 { return .mixed }
        return .imported
    }

    private static func sourceText(_ record: CollectionsAggregator.FlightRecord) -> String {
        switch historySource(record) {
        case .locations:
            String(localized: "flight-log.source.locations", defaultValue: "Recorded locations", comment: "Flight-history provenance from recorded device locations; does not imply continuous GPS.")
        case .photos:
            String(localized: "flight-log.source.photos", defaultValue: "Photos", comment: "Flight-history provenance from imported photo metadata.")
        case .mixed:
            String(localized: "flight-log.source.mixed", defaultValue: "Mixed history", comment: "Flight-history provenance combining sources, possibly photos and recorded or imported locations.")
        case .imported:
            String(localized: "flight-log.source.imported", defaultValue: "Imported history", comment: "Flight-history provenance from a Timeline, GPX, shared-trip or legacy backup import.")
        case .unknown:
            String(localized: "flight-log.source.unknown", defaultValue: "Unknown source", comment: "Flight-history provenance is missing or has an unrecognized raw value; never presented as live tracking.")
        }
    }

    private static func sourceExplanation(_ record: CollectionsAggregator.FlightRecord) -> String {
        switch historySource(record) {
        case .locations:
            String(localized: "flight-log.detail.source.locations-window-note", defaultValue: "Recorded locations can leave gaps. These history boundaries can extend beyond recorded fixes; they are not flight times.", comment: "Flight detail explains that clustered live stay boundaries may extend beyond actual location fixes and do not measure takeoff or landing.")
        case .photos:
            String(localized: "flight-log.detail.source.photos-note", defaultValue: "Photo dates and locations can be sparse or edited. They do not verify flight times or every connection.", comment: "Flight detail explains the limitations of imported photo metadata without treating it as measured personal flight history.")
        case .mixed:
            String(localized: "flight-log.detail.source.mixed-note", defaultValue: "This history combines sources, which may include photos or imports. Gaps and uncertain metadata can hide flight dates and connections.", comment: "Flight detail retains photo/import caution when recorded and imported history have merged.")
        case .imported:
            String(localized: "flight-log.detail.source.imported-note", defaultValue: "Imported locations can leave gaps or incomplete dates. These observations do not verify flight times or every connection.", comment: "Flight detail explains the uncertainty of Timeline, GPX, shared-trip or legacy backup history.")
        case .unknown:
            String(localized: "flight-log.detail.source.unknown-note", defaultValue: "The source of this history is unavailable. Dates, airport matches and connections may be incomplete.", comment: "Flight detail explains missing provenance in older or unrecognized records without inventing a live-location source.")
        }
    }

    private static func airportText(
        code: String, name: String?, resolution: CollectionsAggregator.FlightRecord.AirportResolution
    ) -> String {
        let airport = name.map { "\(code) · \($0)" } ?? code
        switch resolution {
        case .observedNearby:
            return String(localized: "flight-log.detail.airport.observed-nearby", defaultValue: "Observed near \(airport)", comment: "Flight detail airport match supported by a nearby location observation, not verified boarding.")
        case .likely:
            return String(localized: "flight-log.detail.airport.likely", defaultValue: "Likely airport: \(airport)", comment: "Flight detail airport inferred from a nearby city or place, not directly observed at the airport.")
        case .unknown:
            return String(localized: "flight-log.detail.airport.unverified", defaultValue: "Unverified airport: \(airport)", comment: "Flight detail airport retained in older history without metadata establishing how it was matched.")
        }
    }

    /// The question's ends: place names when known, else codes.
    static func ends(_ record: CollectionsAggregator.FlightRecord) -> (from: String, to: String) {
        (record.departurePlace ?? record.departureCode ?? "?",
         record.arrivalPlace ?? record.arrivalCode ?? "?")
    }

    /// Departure-history boundary: a photo stay's last photo, or the live
    /// stay's potentially extended end. This is not an exact last-fix time.
    static func lastSeen(_ record: CollectionsAggregator.FlightRecord) -> Date? {
        record.departureWindowStart
    }

    /// The gap in recorded history, from the departure-history boundary
    /// (possibly extended beyond its final fix) to the arrival boundary.
    static func gapSeconds(_ record: CollectionsAggregator.FlightRecord) -> TimeInterval? {
        guard let start = lastSeen(record) else { return nil }
        let gap = record.date.timeIntervalSince(start)
        return gap > 0 ? gap : nil
    }

    /// Average over the recorded-history gap, not a measured travel speed.
    static func averageSpeedKmh(_ record: CollectionsAggregator.FlightRecord) -> Double? {
        guard let gap = gapSeconds(record), record.distanceKm > 0 else { return nil }
        return record.distanceKm / (gap / 3600)
    }

    /// The window in plain words, from the judge's comparison with the
    /// fastest and usual times by road and rail over the distance.
    static func speedVerdict(_ pace: FlightJudge.Pace) -> String {
        switch pace {
        case .inconclusive:
            String(localized: "flight-log.detail.pace.inconclusive", defaultValue: "The observation window is too broad to distinguish a flight from surface travel.", comment: "Flight detail explanation when elapsed time between observations cannot establish the transport mode.")
        case .onlyPlane:
            String(localized: "flight-log.detail.pace.fast", defaultValue: "The observation window suggests fast travel and supports a possible flight.", comment: "Flight detail explanation of a fast observation window, which is evidence rather than proof that only a plane could travel it.")
        case .planeOrFastTrain:
            String(localized: "flight-log.detail.pace.fast-train", defaultValue: "The observation window could also fit a fast train.", comment: "Flight detail explanation that speed evidence does not distinguish this route from high-speed rail.")
        case .ground:
            String(localized: "flight-log.detail.pace.surface", defaultValue: "The observation window could also fit a drive or train journey.", comment: "Flight detail explanation when elapsed time is compatible with surface travel.")
        case .slow:
            String(localized: "flight-log.detail.pace.long", defaultValue: "The long observation window also allows travel on the surface.", comment: "Flight detail explanation when a long gap leaves transport mode inconclusive.")
        }
    }

    /// The reason in a sentence, with the judge's numbers where it has
    /// them.
    static func evidenceSentence(
        _ evidence: CollectionsAggregator.CandidateEvidence, record: CollectionsAggregator.FlightRecord
    ) -> String {
        let distance = UnitsFormatter.formatDistance(kilometers: record.distanceKm)
        let window = gapSeconds(record).map(durationText)
        switch evidence {
        case .seenInAir:
            if let kmh = record.assessment?.airborneKmh, kmh.isFinite, kmh > 0 {
                let speed = speedText(kmh)
                return String(localized: "flight-log.detail.evidence.fast-locations", defaultValue: "Locations recorded on the way imply about \(speed) between observations. This supports a flight.", comment: "Flight detail evidence from a fast location pair, phrased as an inference rather than verified airborne motion.")
            }
            return String(localized: "flight-log.detail.evidence.fast-locations.plain", defaultValue: "Locations recorded on the way suggest fast travel. This supports a flight.", comment: "Flight detail evidence from a fast location pair when no usable numeric speed is retained.")
        case .tooFastForSurface:
            if let window {
                return String(localized: "flight-log.detail.evidence.short-history-window", defaultValue: "The locations are \(distance) apart, with a history gap of \(window). This suggests fast travel.", comment: "Flight detail evidence giving endpoint distance and the recorded-history gap, whose boundary may include a clustered extension; does not claim surface travel is impossible.")
            }
            return String(localized: "flight-log.detail.evidence.short-window.plain", defaultValue: "The distance and timing of the observations suggest fast travel.", comment: "Flight detail speed evidence without a complete retained observation window.")
        case .airportToAirport:
            return String(localized: "flight-log.detail.evidence.airports", defaultValue: "Locations were recorded near different airports. This supports a possible flight, but does not establish boarding.", comment: "Flight detail evidence from airport proximity rather than verified passenger activity.")
        case .acrossWater:
            return String(localized: "flight-log.detail.evidence.water", defaultValue: "The places appear to be separated by water. A flight may explain the gap.", comment: "Flight detail evidence from the existing island/place heuristic, without asserting a measured sea crossing or excluding a ferry.")
        case .tooFarOverland:
            if let window {
                return String(localized: "flight-log.detail.evidence.long-history-distance", defaultValue: "The locations are \(distance) apart, with a history gap of \(window). A flight may explain the distance.", comment: "Flight detail evidence from a long route and the recorded-history gap, whose boundary may include a clustered extension; does not exclude a train or car.")
            }
            return String(localized: "flight-log.detail.evidence.long-distance.plain", defaultValue: "A flight may explain the distance between the recorded places.", comment: "Flight detail long-distance evidence when the exact observation gap is unavailable.")
        case .longGap:
            return String(localized: "flight-log.detail.evidence.long-gap", defaultValue: "The locations are far apart, with a long gap between them. You may have flown.", comment: "Flight detail evidence from sparse history, explicitly preserving uncertainty about transport mode.")
        }
    }

    static func evidenceSymbol(_ evidence: CollectionsAggregator.CandidateEvidence) -> String {
        switch evidence {
        case .seenInAir: "airplane"
        case .tooFastForSurface: "bolt"
        case .airportToAirport: "airplane.circle"
        case .acrossWater: "water.waves"
        case .tooFarOverland: "road.lanes"
        case .longGap: "clock.badge.questionmark"
        }
    }

    /// "From Greece to Italy", or "Within Greece".
    static func countriesText(_ record: CollectionsAggregator.FlightRecord) -> String? {
        guard let departure = record.departureISO, let arrival = record.arrivalISO else { return nil }
        let from = localizedCountryName(iso: departure, fallback: departure) ?? departure
        if departure == arrival {
            return String(localized: "collections.flight-detail.country-same", defaultValue: "Within \(from)", comment: "Flight detail line when both ends of a flight are in the same country.")
        }
        let to = localizedCountryName(iso: arrival, fallback: arrival) ?? arrival
        return String(localized: "collections.flight-detail.countries", defaultValue: "From \(from) to \(to)", comment: "Flight detail line naming the countries at both ends of a flight.")
    }

    /// A time where it happened, its zone named. Saved times include the
    /// year because the separate history window can span several years.
    static func timeText(_ date: Date, zone: TimeZone, includingYear: Bool = false) -> String {
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated).hour().minute()
            .timeZone(.specificName(.short))
        if includingYear { style = style.year() }
        style.timeZone = zone
        return date.formatted(style)
    }

    /// "29 Nov", where it happened.
    static func shortDayText(_ date: Date, zone: TimeZone) -> String {
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated)
        style.timeZone = zone
        return date.formatted(style)
    }

    static func dayText(_ date: Date, zone: TimeZone) -> String {
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated).year()
        style.timeZone = zone
        return date.formatted(style)
    }

    static func zoneName(_ zone: TimeZone, at date: Date) -> String {
        var style = Date.FormatStyle().timeZone(.specificName(.short))
        style.timeZone = zone
        return date.formatted(style)
    }

    /// "19 h 40 min", or "3 d 4 h" past two days.
    static func durationText(_ seconds: TimeInterval) -> String {
        let units: Set<Duration.UnitsFormatStyle.Unit> = seconds >= 48 * 60 * 60
            ? [.days, .hours] : [.hours, .minutes]
        return Duration.seconds(seconds).formatted(.units(
            allowed: units, width: .abbreviated, maximumUnitCount: 2,
            fractionalPart: .hide(rounded: .toNearestOrAwayFromZero)
        ))
    }

    static func speedText(_ kmh: Double) -> String {
        let unit: UnitSpeed = UnitsFormatter.isImperial ? .milesPerHour : .kilometersPerHour
        return Measurement(value: kmh, unit: UnitSpeed.kilometersPerHour).converted(to: unit)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                    numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    /// Why the editor's times can't be saved; nil when they can. The
    /// pickers already keep both inside the allowed range.
    static func problem(with times: FlightTimeOverrides.Times) -> String? {
        if times.arrival <= times.departure {
            return String(localized: "collections.flight-times.problem.order", defaultValue: "Arrival must be after departure.", comment: "Flight times validation message when the arrival is not after the departure.")
        }
        if times.duration < FlightTimeOverrides.minimumDuration {
            let minimum = FlightLogView.formatHours(FlightTimeOverrides.minimumDuration / 3600)
            return String(localized: "collections.flight-times.problem.short", defaultValue: "A flight takes at least \(minimum).", comment: "Flight times validation message when the flight is shorter than the minimum, such as 15 minutes.")
        }
        if times.duration > FlightTimeOverrides.maximumDuration {
            let maximum = FlightLogView.formatHours(FlightTimeOverrides.maximumDuration / 3600)
            return String(localized: "collections.flight-times.problem.long", defaultValue: "A flight can't take longer than \(maximum).", comment: "Flight times validation message when the flight is longer than the maximum, such as 48 hours.")
        }
        return nil
    }

    /// The trips' names, in the order given, each once. A trip that can't
    /// be read is left out: the names are context, never a decision.
    struct TripName: Identifiable {
        let id: UUID
        let name: String
    }

    static func readTripNames(_ ids: [UUID]) -> [TripName] {
        let context = AppDelegate.modelContainer.mainContext
        var seen = Set<UUID>()
        var result: [TripName] = []
        for id in ids where seen.insert(id).inserted {
            var descriptor = FetchDescriptor<Trip>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let trip = try? context.fetch(descriptor).first, !trip.isDeleted else { continue }
            result.append(TripName(id: id, name: trip.displayName))
        }
        return result
    }
}
