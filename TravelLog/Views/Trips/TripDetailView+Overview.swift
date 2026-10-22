//
//  TripDetailView+Overview.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import AppIntents
import FoundationModels
import SwiftUI
import TipKit
import SwiftData
import MapKit
import Photos
import UIKit
import WidgetKit
import os.log

/// Live UI gates for the canonical-title lane, shared by the detail and settings screens.
extension FMLanguagePolicy {
    nonisolated static var canonicalTripTitlesAvailable: Bool {
        FMCapability.current == .available
            && FMCapability.supportsLocale(FMLanguagePolicy.canonicalTitleLocale)
    }

    nonisolated static var selectedLanguageUsesEnglishTitleFallback: Bool {
        let tag = AppLanguagePreference.currentTag()
        guard canonicalTripTitlesAvailable, tag != "en" else { return false }
        return !FMCapability.supportsLocale(AppLanguagePreference.locale(for: tag))
    }
}

extension TripDetailView {

    /// The departure label follows every input of
    /// `TemporaryHomeCards.departurePlaceName`: the homes and temporary
    /// homes, the stays and trips that decide which one the trip left from,
    /// and its start. Reconciliation can keep the trip id while all of them move.
    nonisolated struct DepartureLabelTaskKey: Equatable {
        let tripID: UUID
        let startDate: Date
        let storeToken: Int
    }

    static func departureLabelTaskKey(
        tripID: UUID, startDate: Date, tracker: StoreChangeTracker = .shared
    ) -> DepartureLabelTaskKey {
        DepartureLabelTaskKey(
            tripID: tripID, startDate: startDate,
            storeToken: tracker.token(for: [.home, .temporaryHome, .stay, .trip]))
    }

    /// Whether this trip can carry a suggestion at all: open, or long enough
    /// for the completed rule (the trips list's prefilter). Stored dates only.
    private var mayHaveTemporaryHomeSuggestion: Bool {
        TripsListView.suggestionScope(
            isComplete: trip.isComplete, startDate: trip.startDate, endDate: trip.endDate) != nil
    }

    /// The next local midnight while the trip is open and short of the
    /// suggestion's day threshold, so a page left open crosses into day 14
    /// with no store write or activation. Nil once it is complete or
    /// past the threshold. Pure.
    nonisolated static func nextSuggestionDayBoundary(
        isComplete: Bool, startDate: Date, now: Date, timeZone: TimeZone = .current
    ) -> Date? {
        guard !isComplete,
              Trip.inclusiveDays(from: startDate, in: timeZone, to: now, in: timeZone)
                < TemporaryHomeSuggestion.ongoingMinimumDays else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
    }

    /// The suggestion's load and the form, split off `detailContent` to keep
    /// its modifier chain within the type checker's budget. A short completed
    /// trip observes no store change for it.
    var temporaryHomeContent: some View {
        detailContent
            .background {
                TemporaryHomeSuggestionLoader(
                    tripID: trip.id, observesStore: mayHaveTemporaryHomeSuggestion,
                    clockTick: suggestionClockTick,
                    nextDayBoundary: Self.nextSuggestionDayBoundary(
                        isComplete: trip.isComplete, startDate: trip.startDate, now: .now),
                    load: loadTemporaryHomeSuggestion,
                    onDayBoundary: { suggestionClockTick &+= 1 })
            }
            .sheet(item: $temporaryHomeSheetMode) { mode in
                TemporaryHomeFormSheet(mode: mode)
            }
    }

    // MARK: - Map Section

    /// The route map; its callout's tap shows that stop in the list.
    func mapSection(_ orderedStays: [Stay], onOpenStop: @escaping (PersistentIdentifier) -> Void) -> some View {
        TripRouteMap(stations: Self.mapStations(orderedStays), focus: $mapFocus, onOpenStop: onOpenStop)
    }

    /// The handle on the map's foot, where a drag can't pan the map: down
    /// opens it to two thirds of the page, up or a tap puts it back. It is
    /// also VoiceOver's way to resize the map, itself hidden from it.
    var mapGrabber: some View {
        Button {
            setMapExpanded(!isMapExpanded, revealing: true)
        } label: {
            Capsule()
                .fill(Color(.label).opacity(0.3))
                .frame(width: 36, height: 5)
                // Kept short, clear of the stations the route frames above it.
                .frame(width: 96, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    let drop = value.translation.height
                    guard abs(drop) > 16, abs(drop) > abs(value.translation.width) else { return }
                    setMapExpanded(drop > 0, revealing: true)
                }
        )
        .accessibilityLabel(isMapExpanded
            ? String(localized: "trip-detail.map.collapse", defaultValue: "Collapse map",
                     comment: "VoiceOver label on the handle at the foot of the trip page's opened route map; activating it returns the map to its usual height.")
            : String(localized: "trip-detail.map.expand", defaultValue: "Expand map",
                     comment: "VoiceOver label on the handle at the foot of the trip page's route map; activating it opens the map to two thirds of the screen."))
    }

    /// The map's stations in route order: destinations with nights on the
    /// big ring, visits left the same day on the small one.
    static func mapStations(_ orderedStays: [Stay]) -> [TripMapStation] {
        // The route between the places of the trip: transit stops such as
        // the airports at either end would pull the frame out to the whole
        // journey, so they stay on the Stops list only.
        let destinations = orderedStays.filter { $0.category == .destination }
        let orderedStays = destinations.isEmpty ? orderedStays : destinations
        return orderedStays.map { stay in
            TripMapStation(
                id: stay.persistentModelID,
                name: stay.locality ?? String(localized: "trip-detail.place.unknown", defaultValue: "Unknown", comment: "Fallback place name in trip details."),
                caption: TripDisplayText.stopCaption(stay),
                latitude: stay.centroidLatitude,
                longitude: stay.centroidLongitude,
                isBase: stay.category == .destination && !TimelineStop.isDayTrip(stay))
        }
    }

    // MARK: - Header Section

    /// The title card: the rename controls while editing, then the title,
    /// flags and country with the dates, the brief figures, and the trip's
    /// passport stamps on the right.
    func headerSection(_ orderedStays: [Stay]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if isEditing {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField("Custom trip name", text: $editingName)
                            .font(.headline)
                            .textFieldStyle(.roundedBorder)

                        if !editingName.isEmpty {
                            Button {
                                editingName = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    // The submitted name is the one that commits.
                    .disabled(isSavingRename)

                    // Auto-generated caption + per-trip regenerate button.
                    // The button is shown whenever there's *anything* to
                    // regenerate against (AI title OR legacy summary), so
                    // a trip currently on the destinationSummary fallback
                    // can still be promoted to an AI title without going
                    // to Settings. The displayed text prefers the AI title
                    // when set; otherwise falls back to the legacy summary.
                    let titleLanguageTag = AppLanguagePreference.currentTag()
                    let autoGenText = TripTitleStore.localizedTitle(
                        for: trip,
                        languageTag: titleLanguageTag)
                        ?? TripTitleStore.normalized(trip.aiGeneratedTitle)
                        ?? Trip.curatedJoin(
                            trip.destinationSummary,
                            languageTag: titleLanguageTag)
                    if !autoGenText.isEmpty {
                        HStack(spacing: 6) {
                            Text("Auto-generated: \(autoGenText)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Button {
                                beginRegeneratingTitle()
                            } label: {
                                if isRegeneratingTitle {
                                    ProgressView()
                                        .controlSize(.mini)
                                } else {
                                    Image(systemName: "arrow.clockwise.circle")
                                        .font(.caption)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(
                                isRegeneratingTitle
                                    || !FMLanguagePolicy.canonicalTripTitlesAvailable
                            )
                            .accessibilityLabel("Regenerate trip title")
                        }
                        if !FMLanguagePolicy.canonicalTripTitlesAvailable {
                            Text("Requires Apple Intelligence")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if FMLanguagePolicy.selectedLanguageUsesEnglishTitleFallback {
                            Text("Automatic titles are available in English")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // The trips list's "Set Up a Temporary Home…", here too
                    // for a trip that qualifies, with or without the suggestion.
                    if TemporaryHomeFormSheet.Prefill.isOffered(
                        isComplete: trip.isComplete, startDate: trip.startDate, endDate: trip.endDate) {
                        Button {
                            guard !trip.isDeleted else { return }
                            temporaryHomeSheetMode = .add(prefill: TemporaryHomeFormSheet.Prefill.forTrip(trip))
                        } label: {
                            Label(
                                String(
                                    localized: "trips.context.set-up-temporary-home",
                                    defaultValue: "Set Up a Temporary Home…",
                                    comment: "Trip context menu action that opens the form for a new temporary home, prefilled from this trip."
                                ),
                                systemImage: "house.and.flag"
                            )
                            .font(.subheadline)
                        }
                        .buttonStyle(.borderless)
                        .tint(AppTheme.accent)
                        .padding(.top, 8)
                        .disabled(isSavingRename)
                    }
                }
                .padding(.bottom, 12)
            }

            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(trip.displayName)
                        .font(.system(size: titleSize, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)

                    // Flags and the countries by name on one line, the
                    // dates on the next: no separator to read past.
                    let codes = trip.countryCodeList
                    VStack(alignment: .leading, spacing: 3) {
                        if !codes.isEmpty {
                            HStack(spacing: 8) {
                                FlagRow(codes: Array(codes.prefix(3)), size: .regular)
                                ViewThatFits(in: .horizontal) {
                                    if let names = TripDisplayText.countryNames(codes) {
                                        Text(names)
                                    }
                                    if let count = TripDisplayText.countries(codes) {
                                        Text(count)
                                    }
                                }
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(TripDisplayText.countryNames(codes) ?? "")
                        }
                        Text(formattedDateRange)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.top, 4)

                    // One line while it fits, the distance below when it
                    // does not, stacked when the text size or the language
                    // makes even the figures too wide.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            overviewStats
                            distanceStat
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline, spacing: 14) {
                                overviewStats
                            }
                            distanceStat
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            overviewStats
                            distanceStat
                        }
                    }
                    .padding(.top, 12)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                TripStampCluster(entries: stampEntries(orderedStays))
            }
        }
        .padding(EdgeInsets(top: 15, leading: 16, bottom: 16, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.card, in: .rect(cornerRadius: AppTheme.cardRadius))
    }

    /// Each country's first entry on this trip, in the trip's country order.
    private func stampEntries(_ orderedStays: [Stay]) -> [TripStampCluster.Entry] {
        trip.countryCodeList.map { code in
            let entry = orderedStays.first { $0.isoCountryCode?.caseInsensitiveCompare(code) == .orderedSame }
            let date = entry.map {
                PassportStamp.entryDate($0.startTime, in: StayTimeZone.resolve($0.timeZoneIdentifier))
            } ?? trip.startDate
            return TripStampCluster.Entry(iso: code, date: date)
        }
    }

    /// Days (or the Active pill and the day count), places and photos, each
    /// number in the statistic face.
    @ViewBuilder
    private var overviewStats: some View {
        if !trip.isComplete {
            ActiveStatePill()
            // The same civil-day rule as the Trips row and the widget.
            TimelineView(.everyMinute) { context in
                if !trip.isDeleted, trip.modelContext != nil {
                    let day = TripsListView.ongoingDisplayDay(for: trip, now: context.date)
                    Text(TripOverviewStat.emphasizing(
                        ActiveTripRow.dayText(day), value: day.formatted(.number.grouping(.never))))
                }
            }
        } else if let days = trip.durationDays {
            Text(TripOverviewStat.emphasizing(
                days == 1
                    ? String(localized: "trip-detail.duration-days.one", defaultValue: "\(days, format: .number.grouping(.never)) day", comment: "Trip detail duration of one day.")
                    : String(localized: "trip-detail.duration-days.other", defaultValue: "\(days, format: .number.grouping(.never)) days", comment: "Trip detail duration of multiple days."),
                value: days.formatted(.number.grouping(.never))))
        }

        let destCount = trip.destinationCount
        if destCount > 0 {
            Text(TripOverviewStat.emphasizing(
                TripDisplayText.places(destCount),
                value: destCount.formatted(.number.grouping(.never))))
        }

        let photoCount = photoPresentation.count
        if photoCount > 0 {
            Text(TripOverviewStat.emphasizing(
                TripDisplayText.photos(photoCount),
                value: photoCount.formatted(.number.grouping(.never))))
        }
    }

    /// How far this trip went, from the home it left (the departure-home
    /// anchor every destination stay carries). Transit stops are not
    /// counted here.
    @ViewBuilder
    private var distanceStat: some View {
        if let km = farthestFromHomeKm {
            TripDistanceCaption(kilometers: km, tripID: trip.id, tripStart: trip.startDate)
        }
    }

    // MARK: - Temporary Home

    /// The suggestion at the top of the page, under the map. Hidden while editing.
    @ViewBuilder
    var temporaryHomeSuggestionSection: some View {
        if let suggestion = temporaryHomeSuggestion, !isEditing {
            TemporaryHomeSuggestionLine(
                candidate: suggestion,
                onSetUp: { temporaryHomeSheetMode = .add(prefill: suggestion.prefill) },
                onNotNow: {
                    TemporaryHomeSuggestion.dismiss(suggestion.tripID)
                    withAnimation { temporaryHomeSuggestion = nil }
                })
                .appCard()
                .padding(.horizontal, AppTheme.gutter)
                .padding(.top, 16)
        }
    }

    /// Reads the trip's stays and the live temporary homes on the main
    /// context; the evaluator returns nil once the user said Not Now.
    /// Assigns only a changed answer, so an unchanged one does not redraw the page.
    private func loadTemporaryHomeSuggestion() {
        var candidate: TemporaryHomeSuggestion.Candidate?
        if !trip.isDeleted, mayHaveTemporaryHomeSuggestion, !TemporaryHomeSuggestion.isDismissed(trip.id) {
            candidate = TemporaryHomeSuggestion.candidate(
                for: trip,
                temporaryHomes: HomeAnchors.collapsingTwins(temporaryHomes.filter { !$0.isDeleted }),
                now: .now)
        }
        if candidate != temporaryHomeSuggestion { temporaryHomeSuggestion = candidate }
    }


    /// The farthest destination's distance from the departure home. Nil
    /// when nothing was stamped, and when the value is the no-home
    /// sentinel (`Double.greatestFiniteMagnitude`) — half the Earth's
    /// circumference bounds any real distance.
    private var farthestFromHomeKm: Double? {
        let km = trip.destinations
            .map(\.distanceFromHomeKm)
            .filter { $0 > 0 && $0 < 25_000 }
            .max()
        return km
    }

    // MARK: - Helpers

    /// "12 to 20 Sep 2026"; an open trip has no end: "Since 14 Oct".
    /// Read in the trip's own zones, as its day count is.
    private var formattedDateRange: String {
        TripDisplayText.tripDates(trip, includeYear: true)
    }

    /// Regenerate just this one trip's AI title using a non-greedy sampler
    /// (different from Stage 5's deterministic `.greedy` pass), so the user
    /// gets a second take when the first AI title was bad. Preserves
    /// `customName` — only `aiGeneratedTitle` changes.
    private func beginRegeneratingTitle() {
        // Capture synchronously while the bound model is known alive. A
        // remote delete/reclassification can invalidate it before an
        // unstructured Task begins, and reading `trip.id` then can trap.
        guard !trip.isDeleted, !isRegeneratingTitle else { return }
        let tripID = trip.id
        let tripIdentifier = trip.persistentModelID
        isRegeneratingTitle = true
        Task {
            await regenerateThisTitle(
                tripID: tripID,
                tripIdentifier: tripIdentifier)
        }
    }

    private func regenerateThisTitle(
        tripID: UUID,
        tripIdentifier: PersistentIdentifier
    ) async {
        defer { isRegeneratingTitle = false }
        let languageTag = AppLanguagePreference.currentTag()
        let targetLocale = AppLanguagePreference.locale(for: languageTag)
        let model = SystemLanguageModel.default
        let targetIsSupported = languageTag != "en"
            && model.supportsLocale(targetLocale)

        let newTitle: String?
        if targetIsSupported {
            // A translation is always derived from a stable canonical English
            // source. Explicit refresh asks for a new canonical concept first,
            // then localizes that result — the same “second take” semantics as
            // the English UI.
            if let canonicalTitle = await AppDelegate.tripClassifier.regenerateTitle(
                for: tripID,
                tripIdentifier: tripIdentifier
            ) {
                await AppDelegate.tripTitleLocalizationService.resetFailures(
                    tripID: tripID,
                    languageTag: languageTag)
                let localizedTitle = await AppDelegate.tripTitleLocalizationService.localizedTitle(
                    for: tripID,
                    tripIdentifier: tripIdentifier,
                    languageTag: languageTag,
                    force: true)
                // The canonical regeneration already succeeded. A transient
                // translation failure must not turn that durable new English
                // fallback into a false total-failure alert.
                newTitle = localizedTitle ?? canonicalTitle
            } else {
                newTitle = nil
            }
        } else {
            // English is the canonical lane. An unsupported app language
            // deliberately falls back to this same durable title.
            newTitle = await AppDelegate.tripClassifier.regenerateTitle(
                for: tripID,
                tripIdentifier: tripIdentifier)
        }
        if newTitle != nil {
            WidgetCenter.shared.reloadAllTimelines()
        }
        // Surface the silent failure (nil ⇒ AI unavailable, pipeline busy,
        // or both attempts rejected). Without this the spinner just stops and
        // the title is unchanged, reading as a no-op the user can't explain.
        if newTitle == nil {
            titleRegenFailed = true
        }
    }
}

// MARK: - Timeline Stay Row

/// A single row in the trip timeline.
///
/// Destination stays get a full card with location details.
/// Transit stays get a compact, understated representation.
/// In edit mode, tapping shows a category picker.
/// "12 km from home", or "12 km from Brussels" for a trip that left from a
/// temporary home. Owns the store-token subscription its departure label
/// needs, so a stay or trip change elsewhere redraws this line only.
private struct TripDistanceCaption: View {
    let kilometers: Double
    let tripID: UUID
    let tripStart: Date
    @Environment(\.modelContext) private var modelContext
    @State private var departurePlaceName: String?

    var body: some View {
        Text(TripOverviewStat.emphasizing(
            caption, value: UnitsFormatter.formatDistance(kilometers: kilometers)))
            .task(id: TripDetailView.departureLabelTaskKey(tripID: tripID, startDate: tripStart)) {
                load()
            }
    }

    private var caption: String {
        let km = kilometers
        if let place = departurePlaceName {
            return String(localized: "trip-detail.distance-from-place", defaultValue: "\(UnitsFormatter.formatDistance(kilometers: km)) from \(place)", comment: "Trip detail caption giving the farthest destination's distance from the temporary home the trip left from; the placeholders are a formatted distance and that place's name.")
        }
        return String(localized: "trip-detail.distance-from-home", defaultValue: "\(UnitsFormatter.formatDistance(kilometers: km)) from home", comment: "Trip detail caption giving the farthest destination's distance from home; the placeholder is a formatted distance.")
    }

    /// With no temporary home this is one fetch. A failed read keeps the line as it was.
    private func load() {
        do {
            departurePlaceName = try TemporaryHomeCards.departurePlaceName(
                tripStart: tripStart, container: modelContext.container)
        } catch {
            Logger(subsystem: "com.travellog.app", category: "TripDetailView")
                .error("Trip departure place read failed: \(error.localizedDescription)")
        }
    }
}

/// The trip's passport stamps beside its title, in visit order: one at
/// full size; two on a diagonal; three in a triangle. Each stays clear of
/// the others (with room for its tilt), so no lettering is ever covered.
struct TripStampCluster: View {
    struct Entry {
        let iso: String
        let date: Date
    }

    let entries: [Entry]

    var body: some View {
        let shown = Array(entries.prefix(3))
        if !shown.isEmpty {
            let layout = Self.layout(for: shown.count)
            ZStack {
                ForEach(Array(shown.enumerated()), id: \.offset) { index, entry in
                    PassportStamp(iso: entry.iso, date: entry.date, size: layout.size)
                        .offset(layout.offsets[index])
                }
            }
            .frame(width: layout.frame.width, height: layout.frame.height)
        }
    }

    private struct Layout {
        let size: CGFloat
        let offsets: [CGSize]
        let frame: CGSize
    }

    /// Centres at least a stamp and a few points apart: a stamp's tilt
    /// carries its corners up to some 6% beyond its square.
    private static func layout(for count: Int) -> Layout {
        switch count {
        case 1:
            Layout(size: 84, offsets: [.zero], frame: CGSize(width: 92, height: 92))
        case 2:
            Layout(size: 58,
                   offsets: [CGSize(width: -18, height: -31), CGSize(width: 18, height: 31)],
                   frame: CGSize(width: 98, height: 126))
        default:
            Layout(size: 52,
                   offsets: [CGSize(width: -30, height: -29), CGSize(width: 30, height: -29),
                             CGSize(width: 0, height: 29)],
                   frame: CGSize(width: 118, height: 116))
        }
    }
}

/// One overview figure: the localized phrase in quiet subheadline with its
/// number in the statistic face. The number is found inside the phrase, so
/// every language keeps its own word order; a phrase that does not contain
/// it verbatim stays plain.
private enum TripOverviewStat {
    static func emphasizing(_ text: String, value: String) -> AttributedString {
        var styled = AttributedString(text)
        styled.font = Font.subheadline
        styled.foregroundColor = Color.secondary
        if !value.isEmpty, let range = styled.range(of: value) {
            styled[range].font = AppTheme.stat(.title3)
            styled[range].foregroundColor = Color.primary
        }
        return styled
    }
}

/// Runs the trip detail's suggestion load whenever the trip, its stays, the
/// temporary homes or the clock change, and calls `onDayBoundary` at
/// `nextDayBoundary`. The store-token read lives here so those changes
/// redraw this empty view, not the page.
private struct TemporaryHomeSuggestionLoader: View {
    let tripID: UUID
    let observesStore: Bool
    let clockTick: Int
    let nextDayBoundary: Date?
    let load: () -> Void
    let onDayBoundary: () -> Void

    private struct TaskKey: Equatable {
        let tripID: UUID
        let storeToken: Int
        let clockTick: Int
    }

    var body: some View {
        Color.clear
            .task(id: TaskKey(
                tripID: tripID,
                storeToken: observesStore
                    ? StoreChangeTracker.shared.token(for: [.temporaryHome, .stay, .trip]) : 0,
                clockTick: clockTick)) {
                load()
            }
            .task(id: nextDayBoundary) {
                guard let next = nextDayBoundary else { return }
                // One second past it, as the trips list's clocks do.
                do { try await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow) + 1)) } catch { return }
                onDayBoundary()
            }
    }
}
