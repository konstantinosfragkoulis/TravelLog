//
//  FlightDetailSheet.swift
//  TravelLog
//
//  One flight or possible flight in full, opened from the Flight Log: where
//  the user was on either side, the window the data leaves between them,
//  the evidence in plain words and the arc on a map, with the log's answers,
//  the ends the user changes (`FlightRouteOverrides`), the stops they add
//  (`FlightStops`) and the flight-times editor (`FlightTimeOverrides`). Renders the aggregate's record; the only reads
//  are the trips' names and the bundled airports.
//

import SwiftUI
import SwiftData
import MapKit

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

    /// Why an answer did not land: the flight changed under it (a refresh
    /// or an import), or the save failed.
    enum Refusal {
        case changed, failed

        var title: String {
            switch self {
            case .changed:
                String(localized: "flight-log.action.changed", defaultValue: "Flight changed. Check it and try again", comment: "Alert title when a Flight Log answer was refused because the flight's data changed while it was open.")
            case .failed:
                String(localized: "common.save-error.try-again", defaultValue: "Couldn't save. Try again", comment: "Shared alert title after a user-authoritative save fails.")
            }
        }
    }

    /// The Flight Log's writers. The sheet closes before the log runs an
    /// answer; its times and stops save while it stays open.
    struct Actions {
        /// The row can still be written: Confirm, Not a Flight.
        var canAnswer = false
        /// Its stops, times and dismissal (kept by its id) are safe to save.
        var canEditCorrections = false
        /// Confirm a candidate, with the times the user changed (or true to
        /// clear saved ones), and the stops and ends, if changed (nil:
        /// untouched).
        var confirm: (FlightTimeOverrides.Times?, Bool, [String]?, FlightRouteOverrides.Route?) -> Void = { _, _, _, _ in }
        var dismissCandidate: () -> Void = {}
        var notAFlight: () -> Void = {}
        /// A flight's own times; nil goes back to the derived ones. The
        /// closure hears why one did not land.
        var saveTimes: (FlightTimeOverrides.Times?, @escaping @MainActor (Refusal) -> Void) -> Void = { _, _ in }
        /// A flight's stops, in order; empty goes back to nonstop.
        var saveStops: ([String], @escaping @MainActor (Refusal) -> Void) -> Void = { _, _ in }
        /// A flight's ends; an empty route goes back to the detected ones.
        var saveRoute: (FlightRouteOverrides.Route, @escaping @MainActor (Refusal) -> Void) -> Void = { _, _ in }
        var openTrip: (UUID) -> Void = { _ in }
    }

    let subject: Subject
    /// The Airports list's codes, suggested as stops before the hubs.
    let visitedAirportCodes: [String]
    let actions: Actions

    @Environment(\.dismiss) private var dismiss
    /// The flight's times as saved, or a candidate's waiting for Confirm.
    @State private var times: FlightTimeOverrides.Times?
    @State private var isEditingTimes: Bool
    /// What the editor opened with, so an untouched editor is no change.
    @State private var editorStart: FlightTimeOverrides.Times
    @State private var confirmsDiscard = false
    @State private var draftDeparture: Date
    @State private var draftArrival: Date
    @State private var tripNames: [TripName] = []
    /// The flight's stops as saved, or a candidate's waiting for Confirm.
    @State private var stopCodes: [String]
    /// The flight's ends as saved (empty: both detected).
    @State private var routeCodes: FlightRouteOverrides.Route
    /// What the airport picker is choosing, while it is open.
    @State private var picking: AirportPick?
    @State private var airportQuery = ""
    /// Built when the airport picker first opens.
    @State private var airportSearchIndex: FlightStops.SearchIndex?
    @State private var refusal: Refusal?

    init(subject: Subject, editTimes: Bool = false, visitedAirportCodes: [String] = [],
         actions: Actions) {
        self.subject = subject
        self.visitedAirportCodes = visitedAirportCodes
        self.actions = actions
        let record = subject.record
        let saved = record.userTimes
        let draft = saved ?? FlightTimeOverrides.suggested(
            windowStart: record.departureWindowStart, windowEnd: record.date,
            estimatedHours: record.journeyEstimatedHours)
        _times = State(initialValue: saved)
        _isEditingTimes = State(initialValue: editTimes && actions.canEditCorrections)
        _editorStart = State(initialValue: draft)
        _draftDeparture = State(initialValue: draft.departure)
        _draftArrival = State(initialValue: draft.arrival)
        _stopCodes = State(initialValue: record.stops?.map(\.code) ?? [])
        _routeCodes = State(initialValue: record.userRoute ?? FlightRouteOverrides.Route())
    }

    private var isCandidate: Bool {
        if case .candidate = subject { return true }
        return false
    }

    /// The record as the sheet shows it: wearing the ends, stops and times
    /// saved or set here.
    private var record: CollectionsAggregator.FlightRecord {
        subject.record.applyingRoute(routeCodes, resolve: Self.airport)
            .applyingStops(stopCodes, resolve: Self.airport).applyingUserTimes(times)
    }

    /// The ends change here, a candidate's before its answer.
    private var canEditRoute: Bool { actions.canEditCorrections }

    private nonisolated static func airport(_ code: String) -> AirportRecord? {
        AirportDetector.shared.airport(code: code)
    }

    /// A candidate's stops go with Confirm only when the user changed them.
    private var changedStops: [String]? {
        stopCodes == (subject.record.stops?.map(\.code) ?? []) ? nil : stopCodes
    }

    /// A candidate's ends go with Confirm only when the user changed them.
    private var changedRoute: FlightRouteOverrides.Route? {
        routeCodes == (subject.record.userRoute ?? FlightRouteOverrides.Route()) ? nil : routeCodes
    }

    /// Answers the sheet still holds: an editor with changed times, or a
    /// candidate's ends, stops and times waiting for Confirm.
    private var hasUnsavedChanges: Bool {
        (isEditingTimes && draft != editorStart)
            || (isCandidate && (changedStops != nil || changedRoute != nil || times != subject.record.userTimes))
    }

    private var zones: (departure: TimeZone, arrival: TimeZone) {
        (StayTimeZone.resolve(record.departureTimeZoneIdentifier),
         StayTimeZone.resolve(record.arrivalTimeZoneIdentifier))
    }

    private var draft: FlightTimeOverrides.Times {
        FlightTimeOverrides.Times(departure: draftDeparture, arrival: draftArrival)
    }

    private var allowedRange: ClosedRange<Date> {
        FlightTimeOverrides.allowedRange(windowStart: subject.record.departureWindowStart,
                                         windowEnd: subject.record.date)
    }

    var body: some View {
        NavigationStack {
            List {
                if let from = coordinate(record.departureLatitude, record.departureLongitude),
                   let to = coordinate(record.arrivalLatitude, record.arrivalLongitude) {
                    let stops = (record.stops ?? []).map {
                        CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                    }
                    Section {
                        FlightArcMap(from: from, stops: stops, to: to, isConfirmed: !isCandidate)
                            .frame(height: 200)
                            .listRowInsets(EdgeInsets())
                            // A new route frames itself afresh.
                            .id([record.departureCode, record.arrivalCode].map { $0 ?? "" }
                                + (record.stops?.map(\.code) ?? []))
                    }
                }
                Section {
                    header(record)
                }
                Section {
                    journey(record)
                } header: {
                    Text(String(localized: "collections.flight-detail.journey", defaultValue: "Journey", comment: "Flight detail section header for the places before and after a flight and the time between them."))
                }
                Section {
                    clues(record)
                } header: {
                    Text(isCandidate
                         ? String(localized: "collections.flight-detail.clues.candidate", defaultValue: "Why It Looks Like a Flight", comment: "Flight detail section header listing the evidence for a possible flight.")
                         : String(localized: "collections.flight-detail.clues.flight", defaultValue: "About This Flight", comment: "Flight detail section header listing facts about a confirmed flight."))
                }
                routeAndTimingSection(record)
                if case .flight = subject, actions.canAnswer {
                    flightActions(record)
                }
            }
            .navigationTitle(isCandidate
                             ? String(localized: "collections.flight-detail.title.candidate", defaultValue: "Possible Flight", comment: "Navigation title of the detail sheet for a possible flight.")
                             : String(localized: "collections.flight-detail.title.flight", defaultValue: "Flight", comment: "Navigation title of the detail sheet for a confirmed flight."))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        if hasUnsavedChanges { confirmsDiscard = true } else { dismiss() }
                    }
                    .fontWeight(.semibold)
                    .confirmationDialog(
                        String(localized: "collections.flight-detail.discard.title", defaultValue: "Discard your changes?", comment: "Confirmation when closing a flight's detail sheet with times or stops not yet saved or confirmed."),
                        isPresented: $confirmsDiscard, titleVisibility: .visible
                    ) {
                        Button("Discard", role: .destructive) { dismiss() }
                    }
                }
            }
            // Unsaved answers never vanish with a swipe.
            .interactiveDismissDisabled(hasUnsavedChanges)
            .alert(refusal?.title ?? "", isPresented: Binding(
                get: { refusal != nil }, set: { if !$0 { refusal = nil } })
            ) {
                Button("OK", role: .cancel) {}
            }
            .safeAreaInset(edge: .bottom) {
                // The editor has its own buttons; the answers wait for it.
                if isCandidate, !isEditingTimes, actions.canAnswer || actions.canEditCorrections { answerBar }
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
                 : CollectionsAggregator.FlightRecord.route(
                    ends.from, through: record.stops?.map { $0.city ?? $0.code } ?? [], to: ends.to))
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(FlightLogView.flightDateText(record))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !tripNames.isEmpty {
                // The trips on either side: which journey this leg belongs to.
                HStack(spacing: 6) {
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
                if let code, code != place {
                    Text(airport.map { String(localized: "collections.flight-detail.airport", defaultValue: "\(code) · \($0)", comment: "Flight detail line naming an airport: its code, then its name.") } ?? code)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if let airport {
                    Text(airport)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if isDeparture {
                    if let lastSeen = Self.lastSeen(record) {
                        Text(String(localized: "collections.flight-detail.last-seen", defaultValue: "Last seen here \(Self.timeText(lastSeen, zone: zone))", comment: "Flight detail line: when the user was last recorded at the departure place, in its local time."))
                            .font(.subheadline)
                    }
                    if let since = record.departureStayStart {
                        Text(String(localized: "collections.flight-detail.here-since", defaultValue: "Here since \(Self.dayText(since, zone: zone))", comment: "Flight detail line: the day the user arrived at the departure place."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(String(localized: "collections.flight-detail.first-seen", defaultValue: "First seen here \(Self.timeText(record.date, zone: zone))", comment: "Flight detail line: when the user was first recorded at the arrival place, in its local time."))
                        .font(.subheadline)
                    if let until = record.arrivalStayEnd {
                        Text(String(localized: "collections.flight-detail.here-until", defaultValue: "Here until \(Self.dayText(until, zone: zone))", comment: "Flight detail line: the day the user left the arrival place."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
                        Text(String(localized: "collections.flight-detail.gap", defaultValue: "\(Self.durationText(gap)) with no location", comment: "Flight detail line: how long the data has no location between the two places."))
                    } icon: {
                        Image(systemName: "airplane")
                            .foregroundStyle(AppTheme.accent)
                    }
                    .font(.subheadline.weight(.medium))
                    .labelStyle(.titleAndIcon)
                }
                let distance = UnitsFormatter.formatDistance(kilometers: record.distanceKm)
                if let speed = Self.averageSpeedKmh(record) {
                    Text(String(localized: "collections.flight-detail.distance-speed", defaultValue: "\(distance) · \(Self.speedText(speed)) on average", comment: "Flight detail line: the distance between the two places, then the average speed over the time with no location."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text(distance)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                // The estimate, under the gap it fits in, until the user
                // sets the times (Route and Timing then shows them).
                if record.userTimes == nil, record.estimatedAirHours > 0 {
                    Text(String(localized: "collections.flight-detail.air-time", defaultValue: "About \(FlightLogView.formatHours(record.estimatedAirHours)) in the air", comment: "Flight detail line under the distance and average speed: the estimated time in the air, from the distance."))
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
        // Under "Why It Looks Like a Flight" only a pace that points to a
        // flight; a confirmed flight's facts keep every verdict.
        if let assessment = record.assessment,
           !isCandidate || Self.pointsToFlight(FlightJudge.pace(assessment)) {
            Label {
                Text(Self.speedVerdict(FlightJudge.pace(assessment)))
            } icon: {
                Image(systemName: "speedometer")
                    .foregroundStyle(AppTheme.accent)
            }
        }
        if let countries = Self.countriesText(record) {
            Label {
                Text(countries)
            } icon: {
                Image(systemName: "globe")
                    .foregroundStyle(AppTheme.accent)
            }
        }
        if record.timeZonesCrossed > 0 {
            let count = record.timeZonesCrossed.formatted(.number.grouping(.never))
            Label {
                Text(record.timeZonesCrossed == 1
                     ? String(localized: "collections.flight-detail.time-zones.one", defaultValue: "Crosses about \(count) time zone", comment: "Flight detail line for a flight spanning one solar time zone.")
                     : String(localized: "collections.flight-detail.time-zones.other", defaultValue: "Crosses about \(count) time zones", comment: "Flight detail line for a flight spanning several solar time zones."))
            } icon: {
                Image(systemName: "clock.arrow.2.circlepath")
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
        if canEditRoute {
            endRow(.departure, record)
            if picking == .departure { airportPicker(record) }
        }
        if stops.isEmpty {
            HStack(spacing: 12) {
                Label {
                    Text(String(localized: "collections.flight-stops.nonstop", defaultValue: "Nonstop", comment: "Flight detail row for a flight with no connection."))
                } icon: {
                    Image(systemName: "airplane")
                        .foregroundStyle(AppTheme.accent)
                }
                Spacer(minLength: 8)
                if picking != .stop, actions.canEditCorrections {
                    Button(addStopTitle) {
                        beginPicking(.stop)
                    }
                    .buttonStyle(.borderless)
                }
            }
        } else {
            let legs = record.legs
            ForEach(Array(legs.enumerated()), id: \.offset) { index, leg in
                legRow(leg, hours: record.estimatedAirHours(of: leg))
                if index < stops.count {
                    stopRow(stops[index], at: index)
                }
            }
            if stops.count < FlightStops.maximumStops, picking != .stop, actions.canEditCorrections {
                Button {
                    beginPicking(.stop)
                } label: {
                    Label(addStopTitle, systemImage: "plus")
                }
            }
        }
        if picking == .stop {
            airportPicker(record)
        }
        if canEditRoute {
            endRow(.arrival, record)
            if picking == .arrival { airportPicker(record) }
        }
    }

    /// Where the flight left from or landed: the airport, else the place
    /// the data saw, with Change.
    @ViewBuilder
    private func endRow(_ side: Side, _ record: CollectionsAggregator.FlightRecord) -> some View {
        let isDeparture = side == .departure
        let code = isDeparture ? record.departureCode : record.arrivalCode
        let airport = isDeparture ? record.departureAirportName : record.arrivalAirportName
        let place = isDeparture ? record.departureName : record.arrivalName
        let title = isDeparture
            ? String(localized: "collections.flight-route.from", defaultValue: "From", comment: "Flight detail label above the airport (or place) the flight left from.")
            : String(localized: "collections.flight-route.to", defaultValue: "To", comment: "Flight detail label above the airport (or place) the flight landed at.")
        HStack(spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(code.map { code in
                        airport.map { String(localized: "collections.flight-detail.airport", defaultValue: "\(code) · \($0)", comment: "Flight detail line naming an airport: its code, then its name.") } ?? code
                    } ?? place ?? "?")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                }
            } icon: {
                Image(systemName: isDeparture ? "airplane.departure" : "airplane.arrival")
                    .foregroundStyle(AppTheme.accent)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if picking != AirportPick(side) {
                Button(String(localized: "collections.flight-route.change", defaultValue: "Change", comment: "Flight detail button that picks a different airport for where a flight left from or landed.")) {
                    beginPicking(AirportPick(side))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(isDeparture
                    ? String(localized: "collections.flight-route.change-from.accessibility", defaultValue: "Change where you flew from", comment: "VoiceOver label for the button that picks a different departure airport for a flight.")
                    : String(localized: "collections.flight-route.change-to.accessibility", defaultValue: "Change where you landed", comment: "VoiceOver label for the button that picks a different arrival airport for a flight.")))
            }
        }
    }

    @ViewBuilder
    private func legRow(_ leg: CollectionsAggregator.FlightRecord.Leg, hours: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "airplane")
                .font(.caption)
                .foregroundStyle(AppTheme.accent)
                .accessibilityHidden(true)
            Text(leg.routeLabel)
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 8)
            Text("\(UnitsFormatter.formatDistance(kilometers: leg.distanceKm)) · ≈ \(FlightLogView.formatHours(hours))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
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

    /// What the airport picker chooses: a stop, or one of the ends.
    private enum AirportPick: Equatable {
        case stop, departure, arrival

        init(_ side: Side) { self = side == .departure ? .departure : .arrival }
    }

    /// Suggestions as chips (airports on the way for a stop, near the
    /// detected end for an end), then a search over every scheduled
    /// airport. Without the points they need, the search alone.
    @ViewBuilder
    private func airportPicker(_ record: CollectionsAggregator.FlightRecord) -> some View {
        let pick = picking ?? .stop
        let suggestions = pick == .stop ? stopSuggestions(record) : endSuggestions(pick, record)
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(pick == .stop
                     ? String(localized: "collections.flight-stops.suggested", defaultValue: "On the way", comment: "Caption above suggested connecting airports that lie roughly between a flight's two ends.")
                     : String(localized: "collections.flight-route.nearby", defaultValue: "Nearby", comment: "Caption above suggested airports near where a flight left from or landed, offered as that end of the flight."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(suggestions, id: \.code) { airport in
                            let place = airport.city ?? airport.name ?? airport.code
                            Button {
                                choose(airport.code, for: pick)
                            } label: {
                                AppChip(label: Text(verbatim: "\(place) · \(airport.code)"))
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text(chooseLabel(pick, place: place, code: airport.code)))
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
            TextField(String(localized: "collections.flight-stops.search.prompt", defaultValue: "Airport code, name or city", comment: "Placeholder of the search field for a flight's connecting airport."), text: $airportQuery)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
        }
        let query = airportQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty, let index = airportSearchIndex {
            let excluded = pick == .stop ? excludedStopCodes(record) : excludedEndCodes(pick, record)
            let results = FlightStops.search(query, in: index).filter { !excluded.contains($0.code) }
            if results.isEmpty {
                Text(String(localized: "collections.flight-stops.search.empty", defaultValue: "No airports match.", comment: "Shown under the connecting-airport search when nothing matches."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(results, id: \.code) { airport in
                    let place = airport.city ?? airport.name ?? airport.code
                    Button {
                        choose(airport.code, for: pick)
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
                    .accessibilityLabel(Text(chooseLabel(pick, place: place, code: airport.code)))
                    .accessibilityAddTraits(.isButton)
                }
            }
        }
        if let detected = detectedEndLabel(pick, record) {
            Button {
                setEnd(pick, to: nil)
            } label: {
                Label(String(localized: "collections.flight-route.reset", defaultValue: "Reset to \(detected)", comment: "Flight detail button that puts back the airport (or place) the app detected for this end of the flight, replacing the one the user chose."),
                      systemImage: "arrow.uturn.backward")
            }
        }
        Button("Cancel", role: .cancel) {
            endPicking()
        }
    }

    private func chooseLabel(_ pick: AirportPick, place: String, code: String) -> String {
        switch pick {
        case .stop:
            String(localized: "collections.flight-stops.add.accessibility", defaultValue: "Add a stop in \(place), \(code)", comment: "VoiceOver label for a suggested or found connecting airport: its city, then its code.")
        case .departure, .arrival:
            String(localized: "collections.flight-route.choose.accessibility", defaultValue: "Choose \(place), \(code)", comment: "VoiceOver label for a suggested or found airport offered as where a flight left from or landed: its city, then its code.")
        }
    }

    /// The codes an end cannot take: the other end's and the stops.
    private func excludedEndCodes(_ pick: AirportPick, _ record: CollectionsAggregator.FlightRecord) -> Set<String> {
        let other = pick == .departure ? record.arrivalCode : record.departureCode
        let own = pick == .departure ? record.departureCode : record.arrivalCode
        return Set([other, own].compactMap { $0 } + stopCodes)
    }

    /// Scheduled airports near where the data put the end.
    private func endSuggestions(_ pick: AirportPick, _ record: CollectionsAggregator.FlightRecord) -> [AirportRecord] {
        let detected = record.detectedRoute
        let point = pick == .departure
            ? (detected?.departureLatitude ?? record.departureLatitude, detected?.departureLongitude ?? record.departureLongitude)
            : (detected?.arrivalLatitude ?? record.arrivalLatitude, detected?.arrivalLongitude ?? record.arrivalLongitude)
        guard let latitude = point.0, let longitude = point.1 else { return [] }
        return FlightRouteOverrides.nearby(
            latitude: latitude, longitude: longitude, excluding: excludedEndCodes(pick, record),
            airports: AirportDetector.shared.allAirports)
    }

    /// What Reset puts back, for an end the user set: the detected code,
    /// else the place.
    private func detectedEndLabel(_ pick: AirportPick, _ record: CollectionsAggregator.FlightRecord) -> String? {
        switch pick {
        case .stop: return nil
        case .departure:
            guard record.namedDeparture != nil else { return nil }
            return record.detectedRoute?.departureCode ?? record.departurePlace
        case .arrival:
            guard record.namedArrival != nil else { return nil }
            return record.detectedRoute?.arrivalCode ?? record.arrivalPlace
        }
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

    private func beginPicking(_ pick: AirportPick) {
        if airportSearchIndex == nil {
            airportSearchIndex = FlightStops.SearchIndex(AirportDetector.shared.allAirports)
        }
        if picking != pick { airportQuery = "" }
        picking = pick
    }

    private func endPicking() {
        picking = nil
        airportQuery = ""
    }

    private func choose(_ code: String, for pick: AirportPick) {
        switch pick {
        case .stop: addStop(code)
        case .departure, .arrival: setEnd(pick, to: code)
        }
    }

    private func addStop(_ code: String) {
        guard stopCodes.count < FlightStops.maximumStops, !stopCodes.contains(code) else { return }
        let before = stopCodes
        stopCodes.append(code)
        endPicking()
        saveStops(restoring: before)
    }

    /// A flight's end saves at once (nil: back to the detected one);
    /// refused, the route goes back to what it was. A candidate's waits
    /// for Confirm.
    private func setEnd(_ pick: AirportPick, to code: String?) {
        var route = routeCodes
        if pick == .departure { route.departure = code } else { route.arrival = code }
        endPicking()
        guard route != routeCodes else { return }
        let before = routeCodes
        routeCodes = route
        guard !isCandidate else { return }
        actions.saveRoute(route) { why in
            routeCodes = before
            refusal = why
        }
    }

    private func removeStop(at index: Int) {
        guard stopCodes.indices.contains(index) else { return }
        let before = stopCodes
        stopCodes.remove(at: index)
        saveStops(restoring: before)
    }

    /// A flight's stops save at once; refused, they go back to `before`.
    private func saveStops(restoring before: [String]) {
        guard !isCandidate else { return }
        actions.saveStops(stopCodes) { why in
            stopCodes = before
            refusal = why
        }
    }

    /// A flight's times save at once; refused, the sheet shows the times it
    /// had again, and an editor reopens with what the user entered.
    private func saveTimes(_ value: FlightTimeOverrides.Times?, reopeningEditor: Bool = false) {
        let before = times
        times = value
        guard !isCandidate else { return }
        actions.saveTimes(value) { why in
            times = before
            if reopeningEditor { isEditingTimes = true }
            refusal = why
        }
    }

    // MARK: Flight times

    /// "When did you fly?": the two ends of a window of a day or more,
    /// each a flight the journey's estimate long. nil for a shorter window
    /// or answers that would not fit it.
    private func whenAnswers(
        _ record: CollectionsAggregator.FlightRecord
    ) -> (afterLeaving: FlightTimeOverrides.Times, beforeReaching: FlightTimeOverrides.Times)? {
        guard let gap = Self.gapSeconds(record), gap >= FlightTimeOverrides.questionMinimumGap,
              let windowStart = record.departureWindowStart else { return nil }
        let estimate = record.journeyEstimatedHours
        let after = FlightTimeOverrides.afterLeaving(
            windowStart: windowStart, windowEnd: record.date, estimatedHours: estimate)
        let before = FlightTimeOverrides.suggested(
            windowStart: windowStart, windowEnd: record.date, estimatedHours: estimate)
        guard FlightTimeOverrides.fits(after, windowStart: windowStart, windowEnd: record.date),
              FlightTimeOverrides.fits(before, windowStart: windowStart, windowEnd: record.date)
        else { return nil }
        return (after, before)
    }

    @ViewBuilder
    private func timingRows(_ record: CollectionsAggregator.FlightRecord) -> some View {
        let duration = String(localized: "collections.flight-times.duration", defaultValue: "In the air", comment: "Flight times label for the flight's duration.")
        if isEditingTimes, actions.canEditCorrections {
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
            if let problem = Self.problem(with: draft) {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.attention)
            } else {
                timeRow(record.stops == nil ? duration : totalTimeTitle,
                        value: FlightLogView.formatHours(draft.duration / 3600))
            }
            Button {
                saveDraft()
            } label: {
                Text(isCandidate
                     ? String(localized: "collections.flight-times.use", defaultValue: "Use These Times", comment: "Button that keeps the times set for a possible flight until the user confirms it.")
                     : String(localized: "collections.flight-times.save", defaultValue: "Save Times", comment: "Button that saves the times the user set for a flight."))
                    .fontWeight(.semibold)
            }
            .disabled(Self.problem(with: draft) != nil)
            Button("Cancel", role: .cancel) {
                isEditingTimes = false
            }
        } else if let times = record.userTimes {
            timeRow(String(localized: "collections.flight-times.departure", defaultValue: "Departure", comment: "Flight times label for when the flight took off."),
                    value: Self.timeText(times.departure, zone: zones.departure, includingYear: true))
            timeRow(String(localized: "collections.flight-times.arrival", defaultValue: "Arrival", comment: "Flight times label for when the flight landed."),
                    value: Self.timeText(times.arrival, zone: zones.arrival, includingYear: true))
            // Through stops the user's times span the connections too.
            timeRow(record.stops == nil ? duration : totalTimeTitle,
                    value: FlightLogView.formatHours(times.duration / 3600))
            editTimesButton(record)
            if actions.canEditCorrections {
                Button {
                    saveTimes(nil)
                } label: {
                    Label(String(localized: "collections.flight-times.use-estimate", defaultValue: "Use Estimate", comment: "Button that removes the times the user set for a flight and goes back to the estimate from distance."),
                          systemImage: "arrow.uturn.backward")
                }
            }
        } else if actions.canEditCorrections, let answers = whenAnswers(record) {
            // Places first, the day second: what the user remembers.
            let ends = Self.ends(record)
            Text(String(localized: "collections.flight-when.question", defaultValue: "When did you fly?", comment: "Flight detail question when the data's gap is a day or more, so the flight could sit at either end of it."))
                .font(.subheadline.weight(.semibold))
            Button {
                chooseTimes(answers.afterLeaving)
            } label: {
                Label(String(localized: "collections.flight-when.after-leaving", defaultValue: "After leaving \(ends.from), \(Self.shortDayText(answers.afterLeaving.departure, zone: zones.departure))", comment: "Answer to When did you fly: right after the user was last recorded at the departure place; the place, then the day."),
                      systemImage: "airplane.departure")
            }
            Button {
                chooseTimes(answers.beforeReaching)
            } label: {
                Label(String(localized: "collections.flight-when.before-reaching", defaultValue: "Before reaching \(ends.to), \(Self.shortDayText(answers.beforeReaching.arrival, zone: zones.arrival))", comment: "Answer to When did you fly: right before the user was first recorded at the arrival place; the place, then the day."),
                      systemImage: "airplane.arrival")
            }
            Button {
                openTimesEditor(record)
            } label: {
                Label(String(localized: "collections.flight-when.exact", defaultValue: "Set Exact Times", comment: "Answer to When did you fly that opens the editor for the flight's departure and arrival times."),
                      systemImage: "clock")
            }
        } else {
            // The estimate reads in the journey, under the gap.
            editTimesButton(record)
        }
    }

    private var totalTimeTitle: String {
        String(localized: "collections.flight-times.total", defaultValue: "Total time", comment: "Flight times label for the duration of a journey through connections, from the first departure to the last arrival.")
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
        let start = times ?? FlightTimeOverrides.suggested(
            windowStart: subject.record.departureWindowStart, windowEnd: subject.record.date,
            estimatedHours: record.journeyEstimatedHours)
        draftDeparture = start.departure
        draftArrival = start.arrival
        editorStart = start
        isEditingTimes = true
    }

    private func chooseTimes(_ chosen: FlightTimeOverrides.Times) {
        saveTimes(chosen)
    }

    private func routeAndTimingFooter(_ record: CollectionsAggregator.FlightRecord) -> String {
        if isEditingTimes {
            return String(localized: "collections.flight-times.footer.zones", defaultValue: "Departure is in local time where you left, arrival where you landed.", comment: "Footer under the flight-time pickers: each time reads in the local time of its own end.")
        }
        if isCandidate, changedRoute != nil {
            return String(localized: "collections.flight-route.footer.on-confirm.changes", defaultValue: "Your changes are saved when you confirm the flight.", comment: "Footer under the airports (and any stops or times) the user changed for a possible flight, which are kept only if the user confirms it.")
        }
        if isCandidate, changedStops != nil {
            return String(localized: "collections.flight-route.footer.on-confirm", defaultValue: "Your stops and times are saved when you confirm the flight.", comment: "Footer under the stops (and any times) set for a possible flight, which are kept only if the user confirms it.")
        }
        if isCandidate, times != nil {
            return String(localized: "collections.flight-times.footer.on-confirm", defaultValue: "These times are saved when you confirm the flight.", comment: "Footer under the times set for a possible flight, which are kept only if the user confirms it.")
        }
        if record.userTimes == nil, whenAnswers(record) != nil {
            return String(localized: "collections.flight-when.footer", defaultValue: "Over a day of your location data is missing here, so the flight could be at either end of the gap. You can change your answer later.", comment: "Footer under When did you fly: the data's gap is too long to tell when the flight was, and the answer can be changed.")
        }
        if record.userTimes != nil {
            return String(localized: "collections.flight-times.footer.set", defaultValue: "Your times replace the estimate in your flight totals. They stay on this device and in your backups.", comment: "Footer under the times the user set for a flight: they replace the distance estimate in the totals and are stored on this device and in backups.")
        }
        return String(localized: "collections.flight-times.footer.air-time", defaultValue: "Air time is estimated from the distance. If you know when you flew, set the times.", comment: "Footer under a flight's route, inviting the user to set the real departure and arrival times instead of the air time estimated from the distance.")
    }

    private func saveDraft() {
        let draft = draft
        guard Self.problem(with: draft) == nil else { return }
        isEditingTimes = false
        saveTimes(draft, reopeningEditor: true)
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

    /// The trip opens from its chip in the header.
    @ViewBuilder
    private func flightActions(_ record: CollectionsAggregator.FlightRecord) -> some View {
        Section {
            Button {
                actions.notAFlight()
            } label: {
                Label(String(localized: "collections.flight.not-a-flight", defaultValue: "Not a Flight", comment: "Flight Log action that removes a flight the user says was not a flight."),
                      systemImage: TransitMode.notFlight.systemImage)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// The question's answers, always in reach under the context.
    private var answerBar: some View {
        VStack(spacing: 8) {
            if actions.canAnswer {
                Button {
                    // The times, stops and ends go with the answer when the
                    // user changed them.
                    let saved = subject.record.userTimes
                    actions.confirm(times == saved ? nil : times, times == nil && saved != nil,
                                    changedStops, changedRoute)
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

    /// The question's ends: place names when known, else codes.
    static func ends(_ record: CollectionsAggregator.FlightRecord) -> (from: String, to: String) {
        (record.departureName ?? record.departureCode ?? "?",
         record.arrivalName ?? record.arrivalCode ?? "?")
    }

    /// When the user was last seen at the departure: the window's start
    /// (a photo stay's last photo, a live stay's end).
    static func lastSeen(_ record: CollectionsAggregator.FlightRecord) -> Date? {
        record.departureWindowStart
    }

    /// The window the data leaves: last fix at the origin to first at the
    /// destination. nil without an origin fix.
    static func gapSeconds(_ record: CollectionsAggregator.FlightRecord) -> TimeInterval? {
        guard let start = lastSeen(record) else { return nil }
        let gap = record.date.timeIntervalSince(start)
        return gap > 0 ? gap : nil
    }

    /// Door-to-door average over the window.
    static func averageSpeedKmh(_ record: CollectionsAggregator.FlightRecord) -> Double? {
        guard let gap = gapSeconds(record), record.distanceKm > 0 else { return nil }
        return record.distanceKm / (gap / 3600)
    }

    static func pointsToFlight(_ pace: FlightJudge.Pace) -> Bool {
        pace == .onlyPlane || pace == .planeOrFastTrain
    }

    /// The window in plain words, from the judge's comparison with the
    /// fastest and usual times by road and rail over the distance.
    static func speedVerdict(_ pace: FlightJudge.Pace) -> String {
        switch pace {
        case .inconclusive:
            String(localized: "collections.flight-detail.speed.inconclusive", defaultValue: "Over a gap this long, the average speed can't tell a flight from a drive.", comment: "Flight detail verdict when the time with no location is over a day, so the average speed proves nothing.")
        case .onlyPlane:
            String(localized: "collections.flight-detail.speed.plane", defaultValue: "Only a plane averages this fast.", comment: "Flight detail verdict when the trip took less time than the fastest car or train would need over the distance.")
        case .planeOrFastTrain:
            String(localized: "collections.flight-detail.speed.fast", defaultValue: "Faster than a car or ferry averages. Only a plane or a fast train comes close.", comment: "Flight detail verdict when the trip was faster than any car, but a fast train could have made it.")
        case .ground:
            String(localized: "collections.flight-detail.speed.ground", defaultValue: "A car or a train could average this too.", comment: "Flight detail verdict when the trip took about as long as a car or train would.")
        case .slow:
            String(localized: "collections.flight-detail.speed.slow", defaultValue: "Slow enough for a ferry, or a drive with stops.", comment: "Flight detail verdict when the trip took longer than a car usually needs.")
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
            if let kmh = record.assessment?.airborneKmh {
                let speed = speedText(kmh)
                return String(localized: "collections.flight-detail.evidence.seen-in-air", defaultValue: "On the way your phone moved at \(speed), faster than anything on the ground.", comment: "Flight detail evidence: two locations recorded on the way were reached at this speed, faster than any car or train.")
            }
            return String(localized: "collections.flight-detail.evidence.seen-in-air.plain", defaultValue: "On the way your phone moved faster than anything on the ground.", comment: "Flight detail evidence: two locations recorded on the way were reached faster than any car or train.")
        case .tooFastForSurface:
            if let window {
                return String(localized: "collections.flight-detail.evidence.too-fast", defaultValue: "You covered \(distance) in \(window), faster than any car or train manages.", comment: "Flight detail evidence: the distance between the two places, then the time between them, too short for any car or train.")
            }
            return String(localized: "collections.flight-detail.evidence.too-fast.plain", defaultValue: "You covered the distance faster than any car or train manages.", comment: "Flight detail evidence: the time between the two places is too short for any car or train.")
        case .airportToAirport:
            return String(localized: "collections.flight-detail.evidence.airports", defaultValue: "You were at one airport just before and at another just after.", comment: "Flight detail evidence: both ends of the possible flight are different airports.")
        case .acrossWater:
            return String(localized: "collections.flight-detail.evidence.across-water", defaultValue: "You crossed between islands, or an island and the mainland, faster than a ferry sails.", comment: "Flight detail evidence: the ends are on different islands, or an island and the mainland, and the time between them is shorter than a ferry needs.")
        case .tooFarOverland:
            if let window {
                return String(localized: "collections.flight-detail.evidence.too-far-overland", defaultValue: "\(distance) in \(window) is farther than a car or train usually gets in that time.", comment: "Flight detail evidence: the distance between the two places, then the time between them, shorter than a car or train usually needs.")
            }
            return String(localized: "collections.flight-detail.evidence.too-far-overland.plain", defaultValue: "This is farther than a car or train usually gets in the time between.", comment: "Flight detail evidence: the time between the two places is shorter than a car or train usually needs.")
        case .longGap:
            return String(localized: "collections.flight-detail.evidence.long-gap", defaultValue: "A long way, with a long time and no location in between: you may have flown.", comment: "Flight detail evidence: a long distance and a long time with no location between the two places, so a flight is likely but unproven.")
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

    /// "3 Aug, 14:20 GMT+3": a time where it happened, its zone named.
    /// Saved times show their year: a window can span a New Year.
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

    /// "19h 40m", or "3d 4h" past two days: the Log's one duration format.
    static func durationText(_ seconds: TimeInterval) -> String {
        let units: Set<Duration.UnitsFormatStyle.Unit> = seconds >= 48 * 60 * 60
            ? [.days, .hours] : [.hours, .minutes]
        return Duration.seconds(seconds).formatted(.units(
            allowed: units, width: .narrow, maximumUnitCount: 2,
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

    private func coordinate(_ latitude: Double?, _ longitude: Double?) -> CLLocationCoordinate2D? {
        guard let latitude, let longitude, latitude.isFinite, longitude.isFinite else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
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

/// The two ends and the great-circle route between them, through the
/// user's stops: plain stations (smaller at the stops), the route line solid
/// for a flight in the log and dashed for a suggestion.
private struct FlightArcMap: View {
    let from: CLLocationCoordinate2D
    let stops: [CLLocationCoordinate2D]
    let to: CLLocationCoordinate2D
    let isConfirmed: Bool

    @Environment(\.self) private var environment

    var body: some View {
        // MapKit resolves overlay colours on its render queue, and the
        // theme's dynamic colours run a main-actor provider: resolve them
        // here so the polylines get plain colours.
        let casing = Color(AppTheme.routeCasing.resolve(in: environment))
        let line = Color(AppTheme.routeLine.resolve(in: environment))
        let route = [from] + stops + [to]
        Map(initialPosition: .automatic, interactionModes: []) {
            MapPolyline(coordinates: route, contourStyle: .geodesic)
                .stroke(casing, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            MapPolyline(coordinates: route, contourStyle: .geodesic)
                .stroke(line, style: StrokeStyle(
                    lineWidth: 3.5, lineCap: .round, lineJoin: .round, dash: isConfirmed ? [] : [7, 7]))
            Annotation(String(), coordinate: from, anchor: .center) { station(size: 16, lineWidth: 3) }
                .annotationTitles(.hidden)
            ForEach(Array(stops.enumerated()), id: \.offset) { _, stop in
                Annotation(String(), coordinate: stop, anchor: .center) { station(size: 11, lineWidth: 2.2) }
                    .annotationTitles(.hidden)
            }
            Annotation(String(), coordinate: to, anchor: .center) { station(size: 16, lineWidth: 3) }
                .annotationTitles(.hidden)
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func station(size: CGFloat, lineWidth: CGFloat) -> some View {
        Circle()
            .fill(AppTheme.routeCasing)
            .overlay(Circle().strokeBorder(AppTheme.routeLine, lineWidth: lineWidth))
            .frame(width: size, height: size)
    }
}
