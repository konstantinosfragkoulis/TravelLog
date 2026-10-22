//
//  SharedTripPreviewSheet.swift
//  TravelLog
//
//  What opening a Travel Log trip file shows: each trip read-only (its map,
//  dates, places, stops and who sent it), then "Were you on this trip?".
//  Yes adds its evidence to this user's history (`SharedTripImporter`); No
//  moves on and saves nothing. Nothing is written before Yes.
//

import MapKit
import SwiftUI

/// Files opened from AirDrop, Messages, Mail, Files or Settings, waiting for
/// the preview.
@MainActor @Observable
final class SharedTripInbox {
    static let shared = SharedTripInbox()

    struct Pending: Identifiable {
        let id = UUID()
        let file: TripShareFile
    }

    var pending: Pending?
    var openError: String?

    /// Reads and checks the file off the main actor, then shows it.
    func open(_ url: URL) {
        Task {
            let result: Result<TripShareFile, TripShareFile.DecodeError> = await Task.detached(priority: .userInitiated) {
                defer { OpenedFile.removeInboxCopy(url) }
                let data: Data?
                do {
                    data = try OpenedFile.read(url) { readable in
                        if let size = try? readable.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                           size > TripShareFile.maximumFileBytes {
                            return nil
                        }
                        return try Data(contentsOf: readable)
                    }
                } catch {
                    return .failure(.unreadable)
                }
                guard let data else { return .failure(.tooLarge) }
                do throws(TripShareFile.DecodeError) { return .success(try TripShareFile.decode(data)) } catch { return .failure(error) }
            }.value
            switch result {
            case .success(let file): pending = Pending(file: file)
            case .failure(let error): openError = Self.message(error)
            }
        }
    }

    static func message(_ error: TripShareFile.DecodeError) -> String {
        switch error {
        case .unsupportedVersion:
            String(localized: "shared-trip.open-error.version",
                   defaultValue: "This trip was shared from a newer version of Travel Log. Update the app to open it.",
                   comment: "Error when a shared trip file uses a format this build does not know.")
        case .tooLarge, .unreadable, .empty:
            String(localized: "shared-trip.open-error.unreadable",
                   defaultValue: "This file isn't a trip Travel Log can open.",
                   comment: "Error when a shared trip file is damaged, empty or not a trip file.")
        }
    }
}

struct SharedTripPreviewSheet: View {
    let file: TripShareFile

    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var isImporting = false
    @State private var result: String?
    @State private var addedBefore = false

    private var trip: SharedTrip? { file.trips.indices.contains(index) ? file.trips[index] : nil }

    var body: some View {
        NavigationStack {
            Group {
                if let trip {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            SharedTripRouteMap(trip: trip)
                                .frame(height: 240)
                                .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))
                            details(trip)
                            if let result {
                                Text(result)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            } else {
                                question
                            }
                        }
                        .padding(AppTheme.gutter)
                    }
                    .background(Color(.systemGroupedBackground))
                }
            }
            .navigationTitle(String(localized: "shared-trip.preview.title", defaultValue: "Shared Trip",
                                    comment: "Title of the sheet that previews a trip someone shared."))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if result != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(index + 1 < file.trips.count
                               ? String(localized: "shared-trip.preview.next", defaultValue: "Next Trip",
                                        comment: "Moves the shared-trip preview to the next trip in the file.")
                               : String(localized: "shared-trip.preview.done", defaultValue: "Done",
                                        comment: "Closes the shared-trip preview after the last trip.")) { advance() }
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "shared-trip.preview.close", defaultValue: "Close",
                                      comment: "Closes the shared-trip preview without adding anything.")) { dismiss() }
                            .disabled(isImporting)
                    }
                }
            }
            .task(id: index) { refreshAddedBefore() }
        }
        .interactiveDismissDisabled(isImporting)
    }

    @ViewBuilder
    private func details(_ trip: SharedTrip) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !trip.countryCodes.isEmpty {
                // The flags are hidden from VoiceOver: name every country.
                FlagRow(codes: Array(trip.countryCodes.prefix(6)), size: .regular)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(TripDisplayText.countryNames(trip.countryCodes) ?? "")
            }
            Text(trip.displayTitle() ?? String(
                localized: "trip.display-name.fallback", defaultValue: "Trip",
                comment: "Fallback display name for a trip with no usable title or destination."))
                .font(.title2.bold())
            Text([SharedTripText.dates(trip), SharedTripText.days(trip)].compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            let places = trip.placeNames
            if !places.isEmpty {
                Text(places.formatted(.list(type: .and)))
                    .font(.subheadline)
            }
            Text([places.isEmpty ? nil : TripDisplayText.places(places.count),
                  SharedTripText.stops(trip.stays.count)].compactMap { $0 }.joined(separator: " · "))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let sender = file.senderName {
                Text(String(localized: "shared-trip.preview.sender", defaultValue: "Shared by \(sender)",
                            comment: "Who sent a shared trip; the placeholder is the name they chose."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if file.trips.count > 1 {
                Text(String(localized: "shared-trip.preview.position",
                            defaultValue: "Trip \(index + 1, format: .number.grouping(.never)) of \(file.trips.count, format: .number.grouping(.never))",
                            comment: "Which trip of a shared file with several is shown, e.g. Trip 2 of 3."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var question: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "shared-trip.question", defaultValue: "Were you on this trip?",
                        comment: "Question the shared-trip preview asks before adding anything."))
                .font(.headline)
            Text(String(localized: "shared-trip.question.own-locations-kept",
                        defaultValue: "Your own locations are always kept.",
                        comment: "Footnote under Were you on this trip: adding a shared trip never replaces the user's own recorded locations."))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if addedBefore {
                Text(String(localized: "shared-trip.question.added-again",
                            defaultValue: "You added this trip before. Only what's new is added.",
                            comment: "Note in the shared-trip preview when this device already added the same trip: adding it again brings in only new places and times."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await addToHistory() }
            } label: {
                HStack {
                    if isImporting { ProgressView() }
                    Text(String(localized: "shared-trip.answer.yes", defaultValue: "Yes, Add to My Trips",
                                comment: "Answer to Were you on this trip that adds the shared trip."))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isImporting)
            Button {
                advance()
            } label: {
                Text(String(localized: "shared-trip.answer.no", defaultValue: "No",
                            comment: "Answer to Were you on this trip that saves nothing."))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isImporting)
        }
    }

    private func refreshAddedBefore() {
        guard let trip else { return }
        addedBefore = (try? SharedTripLedger.record(for: trip.shareID)) != nil
    }

    private func advance() {
        result = nil
        if index + 1 < file.trips.count { index += 1 } else { dismiss() }
    }

    private func addToHistory() async {
        guard let trip, !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            let outcome = try await SharedTripImporter.importTrip(trip, senderName: file.senderName)
            result = Self.message(outcome)
        } catch {
            result = Self.message(error)
        }
    }

    static func message(_ outcome: SharedTripImporter.Outcome) -> String {
        if outcome.saveFailed {
            return String(localized: "shared-trip.result.partial",
                          defaultValue: "Only part of this trip could be saved. Opening the file again is safe and adds the rest.",
                          comment: "Shared trip result when a later batch failed to save.")
        }
        if outcome.processingFailed {
            return String(localized: "shared-trip.result.processing",
                          defaultValue: "The trip's locations were added, but your trips couldn't be rebuilt yet. They will be the next time Travel Log updates.",
                          comment: "Shared trip result when the locations were saved but trips were not rebuilt.")
        }
        if outcome.inserted == 0 {
            return String(localized: "shared-trip.result.nothing-new",
                          defaultValue: "Nothing new to add. Your history already covers this trip.",
                          comment: "Shared trip result when every location was already known or covered by the user's own.")
        }
        return String(localized: "shared-trip.result.added",
                      defaultValue: "Added to your history. You can remove it again under Settings › Import & Export › Shared Trips.",
                      comment: "Shared trip result after a successful add, naming where to undo it.")
    }

    static func message(_ error: SharedTripImporter.ImportError) -> String {
        switch error {
        case .busy:
            String(localized: "shared-trip.error.busy",
                   defaultValue: "Another shared trip is being added. Try again when it finishes.",
                   comment: "Shared trip error when an add or removal is already running.")
        case .homesUnreadable, .evidenceUnreadable, .ledgerUnavailable:
            String(localized: "shared-trip.error.unreadable",
                   defaultValue: "Your history couldn't be read just now, so nothing was added. Try again in a moment.",
                   comment: "Shared trip error when the user's homes, locations or the import record could not be read.")
        }
    }
}

/// The shared trip's places: destinations as markers, and a line only where
/// the file says the sender's route ran unbroken.
struct SharedTripRouteMap: View {
    let trip: SharedTrip

    /// The lines the preview may draw. The sender's GPX and card break the
    /// route wherever evidence was removed or a line would cross a home, but
    /// a version 1 file records no such breaks: joining its fixes in time
    /// order would draw an invented route across a gap the sender left on
    /// purpose. Until a file carries its segments, none is drawn.
    static func routeLines(for trip: SharedTrip) -> [[CLLocationCoordinate2D]] {
        []
    }

    var body: some View {
        let lines = Self.routeLines(for: trip)
        let stops = trip.destinations
        Map(initialPosition: position, interactionModes: [.pan, .zoom]) {
            ForEach(lines.indices, id: \.self) { index in
                MapPolyline(coordinates: lines[index])
                    .stroke(AppTheme.accent, lineWidth: 3)
            }
            ForEach(stops) { stay in
                Marker(stay.placeName ?? "", coordinate: CLLocationCoordinate2D(
                    latitude: stay.latitude, longitude: stay.longitude))
                    .tint(AppTheme.cobaltFill)
            }
        }
        .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
    }

    private var position: MapCameraPosition {
        let points = trip.orderedPings.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            + trip.stays.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        guard let region = TripShareCardRenderer.region(covering: points) else { return .automatic }
        return .region(region)
    }
}
