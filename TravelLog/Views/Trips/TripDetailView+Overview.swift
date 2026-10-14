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

private struct TripMapStay: Identifiable {
    /// The physical row: same-id twins are two pins.
    let id: PersistentIdentifier
    let locality: String?
    let coordinate: CLLocationCoordinate2D
    let isDestination: Bool

    init(_ stay: Stay) {
        id = stay.persistentModelID
        locality = stay.locality
        coordinate = stay.centroid
        isDestination = stay.category == .destination
    }
}

private struct TripMapView: View {
    let stays: [TripMapStay]

    @State private var cameraPosition: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $cameraPosition) {
            ForEach(stays) { stay in
                Annotation(
                    stay.locality ?? String(localized: "trip-detail.place.unknown", defaultValue: "Unknown", comment: "Fallback place name in trip details."),
                    coordinate: stay.coordinate,
                    anchor: .bottom
                ) {
                    VStack(spacing: 2) {
                        Image(systemName: stay.isDestination ? "mappin.circle.fill" : "circle.fill")
                            .font(stay.isDestination ? .title2 : .caption)
                            .foregroundStyle(stay.isDestination ? .red : .orange)
                            .background(
                                Circle()
                                    .fill(.white)
                                    .frame(
                                        width: stay.isDestination ? 28 : 14,
                                        height: stay.isDestination ? 28 : 14)
                            )
                    }
                }
            }

            if stays.count >= 2 {
                MapPolyline(coordinates: stays.map(\.coordinate))
                    .stroke(.tint.opacity(0.6), lineWidth: 3)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .clipShape(.rect(cornerRadius: 0))
    }
}

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

    @ViewBuilder
    func mapSection(_ orderedStays: [Stay]) -> some View {
        TripMapView(stays: orderedStays.map(TripMapStay.init))
    }

    // MARK: - Header Section

    @ViewBuilder
    var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                }
            }

            HStack(alignment: .firstTextBaseline) {
                if !trip.countryFlags.isEmpty {
                    Text(trip.countryFlags)
                        .font(.title)
                }
                Spacer()
                statusBadge
            }

            Text(formattedDateRange)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                if let days = trip.durationDays {
                    Label(days == 1
                          ? String(localized: "trip-detail.duration-days.one", defaultValue: "\(days, format: .number.grouping(.never)) day", comment: "Trip detail duration of one day.")
                          : String(localized: "trip-detail.duration-days.other", defaultValue: "\(days, format: .number.grouping(.never)) days", comment: "Trip detail duration of multiple days."), systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                let destCount = trip.destinationCount
                if destCount > 0 {
                    Label(
                        destCount == 1
                            ? String(localized: "trip-detail.destination-count.one", defaultValue: "\(destCount, format: .number.grouping(.never)) destination", comment: "Trip detail count for one destination.")
                            : String(localized: "trip-detail.destination-count.other", defaultValue: "\(destCount, format: .number.grouping(.never)) destinations", comment: "Trip detail count for multiple destinations."),
                        systemImage: "mappin.and.ellipse"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                // How far this trip went, from the home it left (the
                // departure-home anchor every destination stay carries).
                // Transit stops are not counted here — the timeline shows
                // each leg with its mode.
                if let km = farthestFromHomeKm {
                    TripDistanceCaption(kilometers: km, tripID: trip.id, tripStart: trip.startDate)
                }
            }

            Divider()
        }
    }

    // MARK: - Temporary Home

    var moreActionsMenu: some View {
        Menu {
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
            }
        } label: {
            Label(
                String(
                    localized: "trip-detail.more-actions",
                    defaultValue: "More",
                    comment: "Trip detail toolbar menu button holding more actions for this trip, such as setting up a temporary home."
                ),
                systemImage: "ellipsis.circle"
            )
        }
    }

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
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
                .padding(.horizontal)
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

    /// A completed trip is the resting state and wears no badge; only an
    /// open trip is called out.
    @ViewBuilder
    private var statusBadge: some View {
        if !trip.isComplete {
            Text("In Progress")
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.blue, in: .capsule)
        }
    }

    // MARK: - Helpers

    private var formattedDateRange: String {
        let start = trip.startDate.formatted(date: .long, time: .omitted)
        if let endDate = trip.endDate {
            if Calendar.current.isDate(trip.startDate, inSameDayAs: endDate) { return start }
            return (trip.startDate..<endDate).formatted(
                Date.IntervalFormatStyle(date: .long, time: .omitted)
            )
        }
        return String(localized: "trip-detail.date-range.present", defaultValue: "\(start) - present", comment: "Open trip date range ending at the present; preserve the English hyphen glyph.")
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
        Label(caption, systemImage: "location.north.line")
            .font(.caption)
            .foregroundStyle(.secondary)
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
