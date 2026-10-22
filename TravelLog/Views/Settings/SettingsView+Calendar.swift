//
//  SettingsView+Calendar.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import SwiftUI
import SwiftData
import CoreLocation
import UIKit
import UserNotifications
import Photos
import PhotosUI
import EventKit
import UniformTypeIdentifiers
import WidgetKit
import WebKit
import os.log

/// Settings → Calendar: connection status, calendar selection, and
/// local Calendar-data deletion, which stays reachable after
/// access is revoked because it never reads EventKit.
struct CalendarSettingsView: View {
    @Bindable var model: SettingsModel

    @AppStorage(CalendarEnricher.selectionUnavailableKey)
    private var calendarSelectionUnavailable: Bool = false

    var body: some View {
        List {
            Section {
                statusRows
            } footer: {
                Text(String(
                    localized: "settings.calendar.privacy-footer.plans-and-classification",
                    defaultValue: "With your permission, Travel Log reads events for upcoming plans and local classification of past trips. Calendar bookings do not confirm that a flight was taken. Travel Log never changes your calendar; iOS has no read-only access option. Event details used for plans stay on this device and sync through your private iCloud when sync is on. Notes are never stored, and calendar events are not used to name past trips.",
                    comment: "Settings Calendar footer: optional upcoming plans and on-device classification of past trips, bookings do not prove travel, read-only behavior despite iOS Full Access, storage and title boundaries."
                ))
            }

            if model.calendarAuthStatus == .fullAccess {
                Section {
                    NavigationLink {
                        CalendarSelectionView()
                    } label: {
                        // An explicit selection with no available calendar reads
                        // nothing; say so without drilling in.
                        LabeledContent {
                            if calendarSelectionUnavailable {
                                Text(String(
                                    localized: "settings.calendar.selection-unavailable",
                                    defaultValue: "None available",
                                    comment: "Secondary value on the Settings Calendars row when none of the calendars the user checked is available on this device."
                                ))
                                .foregroundStyle(AppTheme.attention)
                            }
                        } label: {
                            Label("Calendars", systemImage: "calendar")
                        }
                    }
                }
            }

            // Keep local calendar-data deletion available after revocation; this action never reads EventKit.
            Section {
                Button(role: .destructive) {
                    model.showDeleteCalendarDataConfirmation = true
                } label: {
                    HStack {
                        if model.isDeletingCalendarData {
                            ProgressView().controlSize(.small)
                            Text("Deleting Calendar Data…")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Delete Calendar Data")
                        }
                    }
                }
                .disabled(model.isAnyOperationRunning)
            }
        }
        .navigationTitle("Calendar")
        .task {
            await model.refreshCalendarAuthorization()
        }
        .alert("Delete Calendar Data?", isPresented: $model.showDeleteCalendarDataConfirmation) {
            Button("Delete", role: .destructive) { Task { await model.deleteCalendarData() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes all detected upcoming trips and clears AI trip titles so they regenerate. Your trips, stays, and location data are untouched.")
        }
        .alert(model.calendarMatchFailed
            ? Text(String(
                localized: "common.save-error.try-again",
                defaultValue: "Couldn't save. Try again",
                comment: "Shared alert title after a user-authoritative save fails."
            ))
            : Text("Calendar Matching Complete"), isPresented: Binding(
            get: { model.calendarMatchResultMessage != nil },
            set: { if !$0 { model.calendarMatchResultMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if let message = model.calendarMatchResultMessage, !message.isEmpty {
                Text(message)
            }
        }
        .alert("Delete Calendar Data", isPresented: Binding(
            get: { model.calendarDeleteErrorMessage != nil },
            set: { if !$0 { model.calendarDeleteErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if let message = model.calendarDeleteErrorMessage { Text(message) }
        }
    }

    @ViewBuilder
    private var statusRows: some View {
        switch model.calendarAuthStatus {
        case nil:
            // The first off-main EventKit read has not returned yet.
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .leading)

        case .fullAccess:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
                .font(.subheadline)

        case .writeOnly:
            // Shouldn't occur (we only ever request full access), but iOS
            // Settings lets the user downgrade the grant afterwards.
            VStack(alignment: .leading, spacing: 4) {
                Label("Add-Only Access", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppTheme.attention)
                    .font(.subheadline.bold())
                Text("Travel Log can't read events with add-only access. Choose Full Access in Settings. It still never changes your calendar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Open Settings") { SettingsModel.openSystemSettings() }

        case .denied:
            VStack(alignment: .leading, spacing: 4) {
                Label("Calendar Access Denied", systemImage: "xmark.circle.fill")
                    .foregroundStyle(AppTheme.attention)
                    .font(.subheadline.bold())
                Text("Enable calendar access in Settings to detect upcoming trips.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Open Settings") { SettingsModel.openSystemSettings() }

        case .restricted:
            Label("Calendar Access Restricted", systemImage: "lock.fill")
                .foregroundStyle(AppTheme.attention)
                .font(.subheadline)

        default:
            Button("Continue") {
                Task {
                    let granted = await AppDelegate.calendarEnricher.requestFullAccess()
                    await model.refreshCalendarAuthorization()
                    if granted {
                        await AppDelegate.calendarEnricher.startObservingStoreChanges()
                        Task.detached(priority: .background) {
                            await AppDelegate.calendarEnricher.scanUpcomingTrips()
                        }
                    }
                }
            }
        }
    }
}

extension SettingsModel {

    /// Compatibility action for older callers; Calendar cannot confirm past flights.
    func matchCalendarEventsToPastTrips() {
        isMatchingCalendarTrips = true
        Task {
            // The retired Calendar backfill performs no reads or writes.
            let outcome = await AppDelegate.transitInferer.recorroborateUnknownLegs()
            // A committed flight upgrade changes the TravelStats hex-visibility result.
            if outcome.upgraded > 0 {
                WidgetCenter.shared.reloadAllTimelines()
            }
            isMatchingCalendarTrips = false
            let unfinished = outcome.failed || !outcome.complete
            calendarMatchFailed = unfinished
            calendarMatchResultMessage = SettingsView.resultText(
                flights: outcome.upgraded, unfinished: unfinished)
        }
    }

    /// The inferer drains the transit backlog in bounded gate units, then rechecks terminal unknown
    /// legs under the current geometry judge and airport data. It owns every gate unit.
    func detectFlights() {
        isDetectingFlights = true
        Task {
            let outcome = await AppDelegate.transitInferer.detectFlights()
            if outcome.found > 0 {
                WidgetCenter.shared.reloadTimelines(ofKind: "TravelStatsWidget")
            }
            isDetectingFlights = false
            let unfinished = outcome.failed || !outcome.complete
            flightDetectFailed = unfinished
            flightDetectResultMessage = SettingsView.flightDetectText(
                analyzed: outcome.analyzed, found: outcome.found, unfinished: unfinished)
        }
    }

    func deleteCalendarData() async {
        isDeletingCalendarData = true
        defer { isDeletingCalendarData = false }
        // Durable before phase one: if the app is killed between queue,
        // PlannedTrip/cache, and live-title commits, launch resumes the same
        // idempotent wipe. While pending, queue append/restore suppresses
        // generated title artifacts so concurrent healing cannot reintroduce
        // Calendar text.
        DissolvedTripQueue.beginGeneratedTitleRevocation()
        await AppDelegate.calendarEnricher.beginCalendarDataRevocation()
        // A parked trip lives outside SwiftData and may carry an occasion
        // title sourced from Calendar. Scrub that recovery file first and
        // fail closed: deleting live rows while leaving restorable Calendar
        // text behind would make the privacy action misleading.
        do {
            try await Task.detached(priority: .userInitiated) {
                try DissolvedTripQueue.scrubGeneratedTitles()
            }.value
        } catch {
            calendarDeleteErrorMessage = error.localizedDescription
            return
        }
        // PlannedTrip wipe is a store mutation → gated like every foreground
        // mutator. Title clearing uses its own short classifier-owned unit.
        let calendarResult = await PipelineGate.shared.runReturning(
            touching: [.plannedTrip]
        ) {
            await AppDelegate.calendarEnricher.deleteAllCalendarData()
        }
        guard calendarResult.succeeded else {
            calendarDeleteErrorMessage = CocoaError(.fileWriteUnknown)
                .localizedDescription
            return
        }
        // PlannedTrip deletion is already committed. Refresh its only widget
        // immediately, even if the independent title-clear transaction below
        // fails and we have to surface a retry alert.
        WidgetCenter.shared.reloadTimelines(ofKind: "UpcomingTripWidget")
        // One classifier latch spans the unconditional deletion and the
        // language-gated refill, so no in-flight title can land between them.
        // The revocation marker finishes right after the clear, before refill.
        // Search documents cache titles; drop them as soon as the clear commits
        // so no query can match scrubbed Calendar text during regeneration.
        let titleResult = await AppDelegate.tripClassifier
            .clearThenRegenerateAllTitlesForCalendarWipe(
                finishRevocationAfterClear: {
                    Task { @MainActor in TripSearchIndexStore.shared.invalidateAll() }
                    return AppDelegate.finishCalendarDataRevocation()
                })
        guard titleResult.cleared, titleResult.revocationFinished else {
            calendarDeleteErrorMessage = CocoaError(.fileWriteUnknown)
                .localizedDescription
            return
        }
        _ = await AppDelegate.tripTitleLocalizationService
            .generateLocalizedTitlesStage(maxTripsPerCall: nil)
        // Reload UpcomingTrip and CurrentTrip widgets because their process cannot observe tracker changes.
        WidgetCenter.shared.reloadAllTimelines()
    }
}

extension SettingsView {

    /// Committed counts only. An unfinished run (a failed read or save, or a
    /// scan that stopped early) keeps what did commit but never claims that
    /// nothing was found; the alert title then says to try again.
    static func flightDetectText(analyzed: Int, found: Int, unfinished: Bool) -> String {
        var sentences: [String] = []
        if analyzed > 0 {
            if analyzed == 1 {
                sentences.append(String(
                    localized: "settings.flight-detection.analyzed.one",
                    defaultValue: "Analyzed \(analyzed, format: .number.grouping(.never)) new travel leg.",
                    comment: "Flight detection result after analyzing one new travel leg."
                ))
            } else {
                sentences.append(String(
                    localized: "settings.flight-detection.analyzed.other",
                    defaultValue: "Analyzed \(analyzed, format: .number.grouping(.never)) new travel legs.",
                    comment: "Flight detection result after analyzing multiple new travel legs."
                ))
            }
        }
        if found > 0 {
            if found == 1 {
                sentences.append(String(
                    localized: "settings.flight-detection.confirmed.one",
                    defaultValue: "Confirmed \(found, format: .number.grouping(.never)) flight.",
                    comment: "Flight detection result after confirming one flight."
                ))
            } else {
                sentences.append(String(
                    localized: "settings.flight-detection.confirmed.other",
                    defaultValue: "Confirmed \(found, format: .number.grouping(.never)) flights.",
                    comment: "Flight detection result after confirming multiple flights."
                ))
            }
        } else if !unfinished {
            sentences.append(String(
                localized: "settings.flight-detection.none-found",
                defaultValue: "No new flights found. Possible flights you can confirm appear in the Flight Log.",
                comment: "Flight detection result when no new flights were confirmed; the Flight Log lists possible flights to review."
            ))
        }
        return sentences.joined(separator: " ")
    }

    /// Compatibility result for the retired past-calendar matching action.
    static func resultText(flights: Int, unfinished: Bool) -> String {
        guard !unfinished || flights > 0 else { return "" }
        return String(
            localized: "settings.calendar-match.past-flights-not-confirmed",
            defaultValue: "Calendar bookings do not confirm past flights. Review possible flights in the Flight Log.",
            comment: "Result of the retired past-calendar matching action; calendar bookings cannot prove that a person travelled."
        )
    }
}
