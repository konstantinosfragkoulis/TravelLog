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

extension SettingsView {

    @ViewBuilder
    var calendarSection: some View {
        Section {
            switch calendarAuthStatus {
            case .fullAccess:
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline)

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
                            .foregroundStyle(.orange)
                        }
                    } label: {
                        Label("Calendars", systemImage: "calendar")
                    }
                }

                // Backfill calendar-corroborated flights in existing trips; calendar text must not reach titles.
                Button {
                    matchCalendarEventsToPastTrips()
                } label: {
                    HStack {
                        if isMatchingCalendarTrips {
                            ProgressView().controlSize(.small)
                            Text("Matching Calendar Events…")
                                .foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "sparkles.rectangle.stack")
                            Text("Match Calendar Events to Past Trips")
                        }
                    }
                }
                .disabled(isMatchingCalendarTrips || isAnyOperationRunning)

                // Explain once that account sync limits can exclude older calendar history.
                if !thinHistoryAccount.isEmpty && !thinHistoryTipDismissed {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Older events aren't synced", systemImage: "info.circle")
                            .font(.subheadline.bold())
                            .foregroundStyle(.orange)
                        Text("Your “\(thinHistoryAccount)” account only keeps recent events on this device. To let Travel Log confirm flights on your older trips, set Settings → Apps → Calendar → Accounts → \(thinHistoryAccount) → Sync to “All Events”.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Got It") { thinHistoryTipDismissed = true }
                            .font(.caption.bold())
                    }
                }

            case .writeOnly:
                // Shouldn't occur (we only ever request full access), but iOS
                // Settings lets the user downgrade the grant afterwards.
                VStack(alignment: .leading, spacing: 4) {
                    Label("Add-Only Access", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.subheadline.bold())
                    Text("Travel Log can't read events with add-only access. Choose Full Access in Settings. It still never changes your calendar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }

            case .denied:
                VStack(alignment: .leading, spacing: 4) {
                    Label("Calendar Access Denied", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.subheadline.bold())
                    Text("Enable calendar access in Settings to detect upcoming trips.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }

            case .restricted:
                Label("Calendar Access Restricted", systemImage: "lock.fill")
                    .foregroundStyle(.red)
                    .font(.subheadline)

            default:
                Button("Continue") {
                    Task {
                        let granted = await AppDelegate.calendarEnricher.requestFullAccess()
                        calendarAuthStatus = CalendarEnricher.authorizationStatus
                        if granted {
                            await AppDelegate.calendarEnricher.startObservingStoreChanges()
                            Task.detached(priority: .background) {
                                await AppDelegate.calendarEnricher.scanUpcomingTrips()
                            }
                        }
                    }
                }
            }

            // Keep local calendar-data deletion available after revocation; this action never reads EventKit.
            Button(role: .destructive) {
                showDeleteCalendarDataConfirmation = true
            } label: {
                HStack {
                    if isDeletingCalendarData {
                        ProgressView().controlSize(.small)
                        Text("Deleting Calendar Data…")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Delete Calendar Data")
                    }
                }
            }
            .disabled(isAnyOperationRunning)
        } header: {
            Text("Calendar")
        } footer: {
            Text(String(
                localized: "settings.calendar.footer",
                defaultValue: "Travel Log reads your calendar to spot upcoming trips and confirm flights on past ones. It never creates, edits, or deletes events. iOS just doesn't offer a read-only permission. Event details used for trip detection are stored on your device and sync through your private iCloud when sync is enabled; notes are never stored. Calendar events never appear in trip titles. “Match” retries flight detection for older trips; “Delete” removes detected upcoming trips and regenerates AI titles.",
                comment: "Settings footer explaining Calendar access, storage, private iCloud sync, and data actions."
            ))
        }
        .alert("Delete Calendar Data?", isPresented: $showDeleteCalendarDataConfirmation) {
            Button("Delete", role: .destructive) { Task { await deleteCalendarData() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes all detected upcoming trips and clears AI trip titles so they regenerate. Your trips, stays, and location data are untouched.")
        }
        .alert(calendarMatchFailed
            ? Text(String(
                localized: "common.save-error.try-again",
                defaultValue: "Couldn't save. Try again",
                comment: "Shared alert title after a user-authoritative save fails."
            ))
            : Text("Calendar Matching Complete"), isPresented: Binding(
            get: { calendarMatchResultMessage != nil },
            set: { if !$0 { calendarMatchResultMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if let message = calendarMatchResultMessage, !message.isEmpty {
                Text(message)
            }
        }
        .alert("Delete Calendar Data", isPresented: Binding(
            get: { calendarDeleteErrorMessage != nil },
            set: { if !$0 { calendarDeleteErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if let message = calendarDeleteErrorMessage { Text(message) }
        }
    }

    /// Backfill calendar-corroborated flight upgrades for long unknown legs; titles take no calendar input.
    private func matchCalendarEventsToPastTrips() {
        isMatchingCalendarTrips = true
        Task {
            // Backfill reads EventKit ungated and applies short gated writes that revalidate each leg.
            // Do NOT wrap in PipelineGate.run: the gate is non-reentrant, and full-history work would starve SLC writes.
            let outcome = await AppDelegate.transitInferer.recorroborateUnknownLegs()
            // A committed flight upgrade changes the TravelStats hex-visibility result.
            if outcome.upgraded > 0 {
                WidgetCenter.shared.reloadAllTimelines()
            }
            isMatchingCalendarTrips = false
            let unfinished = outcome.failed || !outcome.complete
            calendarMatchFailed = unfinished
            calendarMatchResultMessage = Self.resultText(
                flights: outcome.upgraded, unfinished: unfinished)
        }
    }

    /// The inferer drains the transit backlog in bounded gate units, then rechecks terminal unknown
    /// legs for airport-data changes and Calendar corroboration. It owns every gate unit.
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
            flightDetectResultMessage = Self.flightDetectText(
                analyzed: outcome.analyzed, found: outcome.found, unfinished: unfinished)
        }
    }

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

    /// Committed upgrades only; an unfinished run never claims nothing matched.
    static func resultText(flights: Int, unfinished: Bool) -> String {
        switch flights {
        case 0:
            guard !unfinished else { return "" }
            return String(localized: "settings.calendar-match.none", defaultValue: "No trips needed updating. Nothing in your calendar matched better than what's already there.", comment: "Calendar matching result when no trip titles or flights were updated.")
        case 1:
            return String(localized: "settings.calendar-match.flights.one", defaultValue: "Confirmed \(flights, format: .number.grouping(.never)) flight from calendar events.", comment: "Calendar matching result after confirming one flight and no trip titles.")
        default:
            return String(localized: "settings.calendar-match.flights.other", defaultValue: "Confirmed \(flights, format: .number.grouping(.never)) flights from calendar events.", comment: "Calendar matching result after confirming multiple flights and no trip titles.")
        }
    }

    private func deleteCalendarData() async {
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
