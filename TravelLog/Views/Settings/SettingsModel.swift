//
//  SettingsModel.swift
//  TravelLog
//
//  Operation and permission state shared by Settings and the screens it
//  pushes (Calendar, Import & Export, Maintenance), so an operation started
//  on one screen still disables conflicting actions on every other one.
//

import SwiftUI
import EventKit
import Photos
import UserNotifications
import os.log

/// Settings performance intervals; open Instruments' os_signpost / Points of
/// Interest track and filter on this subsystem and category.
let settingsSignposter = OSSignposter(
    subsystem: "com.travellog.app", category: "SettingsPerformance")

@Observable
final class SettingsModel {

    // MARK: - Maintenance

    var isReclassifying = false
    var isRegeneratingTitles = false
    var titleRegenerationResultMessage: String?
    var isRetryingGeocoding = false
    var isBackfillingHexes = false
    var isDetectingFlights = false
    var flightDetectResultMessage: String?
    var flightDetectFailed = false
    /// A history rebuild left some units unsaved.
    var saveFailed = false

    // MARK: - Import & Export

    var isExporting = false
    var exportFileURL: URL?
    var showExportError = false

    // External-history import flows (Import Google Timeline / Import GPX
    // Track). The two share the alert + progress state; only one can run at
    // a time (isAnyOperationRunning).
    var isImportingTimeline = false
    var showTimelineImportPicker = false
    var showGPXImportPicker = false
    var timelineImportResultMessage: String?
    var timelineImportErrorMessage: String?
    var externalImportIsGPX = false

    // JSON trip-data import flow (Import Trip Data).
    var isImportingTrips = false
    var showTripImportPicker = false
    var pendingTripImport: (
        payload: ImportPayload, preview: ImportPreview,
        fingerprint: String, crossDeviceRepeat: Bool
    )?
    var showTripImportConfirmation = false
    var tripImportResultMessage: String?
    var tripImportErrorMessage: String?

    var isDeleting = false
    var showDeleteConfirmation = false
    var showDeleteError = false

    // MARK: - Photo import

    var isStartingImport = false
    var isCancellingImport = false
    var isDiscardingImport = false
    var showDiscardImportConfirmation = false
    var importErrorMessage: String?
    var showImportError = false
    var canStartFreshAfterImportError = false

    // MARK: - Calendar

    var isMatchingCalendarTrips = false
    var calendarMatchResultMessage: String?
    var calendarMatchFailed = false
    var showDeleteCalendarDataConfirmation = false
    var isDeletingCalendarData = false
    var calendarDeleteErrorMessage: String?

    // MARK: - Memories

    var isGeneratingCurrentYearWrapped = false
    #if DEBUG
    var isForceRegenerating = false
    #endif

    // MARK: - Permissions and capabilities

    var notificationAuthStatus: UNAuthorizationStatus = .notDetermined
    var photoAuthStatus: PHAuthorizationStatus = .notDetermined
    /// Nil until the first off-main EventKit read returns.
    var calendarAuthStatus: EKAuthorizationStatus?

    /// Apple Intelligence availability, snapshotted on appearance and
    /// activation instead of being re-read on every body evaluation.
    var appleIntelligence: FMCapabilityState = FMCapability.current
    var canonicalTripTitlesAvailable = FMLanguagePolicy.canonicalTripTitlesAvailable
    var selectedLanguageUsesEnglishTitleFallback = FMLanguagePolicy.selectedLanguageUsesEnglishTitleFallback

    var isAnyOperationRunning: Bool {
        // Wrapped generation mutates the store, so destructive actions must stay disabled while it runs.
        var running = isReclassifying || isRegeneratingTitles || isRetryingGeocoding || isBackfillingHexes
            || isExporting || isDeleting || isImportingTrips || isImportingTimeline
            || isMatchingCalendarTrips || isDeletingCalendarData || isDetectingFlights
            || isGeneratingCurrentYearWrapped
        #if DEBUG
        running = running || isForceRegenerating
        #endif
        return running
    }

    /// Re-reads the photo, calendar and notification authorization statuses
    /// and the Apple Intelligence snapshot. The EventKit lookup is a
    /// synchronous XPC round trip, so it runs off the main actor, as launch does.
    func refreshAuthorizationStatuses() async {
        let interval = settingsSignposter.beginInterval("SettingsAuthorizationRefresh")
        defer { settingsSignposter.endInterval("SettingsAuthorizationRefresh", interval) }
        // Mirror the live PhotoKit status into PhotoService too: it gates
        // every photo fetch, so a stale value silently empties trip galleries.
        PhotoService.shared.refreshAuthorizationStatus()
        photoAuthStatus = PhotoService.shared.authorizationStatus
        refreshCapabilities()
        let calendar = await Task.detached(priority: .userInitiated) {
            CalendarEnricher.authorizationStatus
        }.value
        if calendarAuthStatus != calendar { calendarAuthStatus = calendar }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        NotificationService.enableDefaultFeaturesIfAuthorized(settings.authorizationStatus)
        notificationAuthStatus = settings.authorizationStatus
    }

    /// Re-reads only the Calendar authorization, off the main actor.
    func refreshCalendarAuthorization() async {
        let calendar = await Task.detached(priority: .userInitiated) {
            CalendarEnricher.authorizationStatus
        }.value
        if calendarAuthStatus != calendar { calendarAuthStatus = calendar }
    }

    func refreshCapabilities() {
        let state = FMCapability.current
        if appleIntelligence != state { appleIntelligence = state }
        let canonical = FMLanguagePolicy.canonicalTripTitlesAvailable
        if canonicalTripTitlesAvailable != canonical { canonicalTripTitlesAvailable = canonical }
        let fallback = FMLanguagePolicy.selectedLanguageUsesEnglishTitleFallback
        if selectedLanguageUsesEnglishTitleFallback != fallback {
            selectedLanguageUsesEnglishTitleFallback = fallback
        }
    }

    static func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
