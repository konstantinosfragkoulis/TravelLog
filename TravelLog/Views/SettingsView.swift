//
//  SettingsView.swift
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

/// Settings screen for managing homes, routine places, and app data.
struct SettingsView: View {
    @Query(sort: \Home.startedAt, order: .reverse) private var allHomes: [Home]
    @Query(sort: \RoutinePlace.label) private var allRoutinePlaces: [RoutinePlace]

    /// Only show current homes (not ended) in the settings list.
    var homes: [Home] { allHomes.filter(\.isCurrent) }

    /// Only show current, active routine places in the settings list.
    var routinePlaces: [RoutinePlace] { allRoutinePlaces.filter(\.isCurrent) }
    @Environment(\.modelContext) private var modelContext

    @State private var showAddHome = false
    @State var showLastHomeAlert = false
    @State private var showAddRoutinePlace = false
    @State private var homeToEdit: Home?
    @State private var routinePlaceToEdit: RoutinePlace?
    @State var isReclassifying = false
    @State var isRegeneratingTitles = false
    @State var titleRegenerationResultMessage: String?
    /// Count of heuristic-only trips (`classifiedByAI == false && !userEdited`)
    /// that Apple Intelligence could re-classify. Recomputed on appear and on
    /// every `.trip` store change; gates the "Enhance History" row.
    @State var enhanceBacklogCount = 0
    @State var isRetryingGeocoding = false
    @State var isBackfillingHexes = false
    @State var isExporting = false
    @State var exportFileURL: URL?

    // External-history import flows (Settings → Import Google Timeline /
    // Import GPX Track). The two share the alert + progress state — only
    // one can run at a time (isAnyOperationRunning).
    @State var isImportingTimeline = false
    @State var showTimelineImportPicker = false
    @State var showGPXImportPicker = false
    @State var timelineImportResultMessage: String?
    @State var timelineImportErrorMessage: String?
    @State var externalImportIsGPX = false

    // JSON trip-data import flow (Settings → Import Trip Data).
    @State var isImportingTrips = false
    @State var showTripImportPicker = false
    @State var pendingTripImport: (
        payload: ImportPayload, preview: ImportPreview,
        fingerprint: String, crossDeviceRepeat: Bool
    )?
    @State var showTripImportConfirmation = false
    @State var tripImportResultMessage: String?
    @State var tripImportErrorMessage: String?
    @State var isDeleting = false
    @State var showDeleteConfirmation = false
    @State var showDeleteError = false
    @State var showExportError = false
    @State var saveFailed = false
    /// Explain why Wrapped generation returned no row.
    @State private var wrappedGenerationFailureMessage: String?

    // Photo-import section state.
    @Query(sort: \PhotoImportState.startedAt, order: .forward)
    var importStates: [PhotoImportState]
    @State var isStartingImport = false
    @State var isCancellingImport = false
    @State var isDiscardingImport = false
    @State var showDiscardImportConfirmation = false
    @State var importErrorMessage: String?
    @State var showImportError = false
    @State var canStartFreshAfterImportError = false

    @AppStorage(AppDelegate.iCloudSyncEnabledKey) var iCloudSyncEnabled = false
    @AppStorage(AppDelegate.lastCloudKitErrorKey) private var lastCloudKitError = ""
    @State private var showRestartAlert = false
    @State private var pendingSyncToggleValue = false
    @State private var showPrivacyPolicy = false

    @AppStorage(NotificationService.countryWelcomeEnabledKey) private var countryWelcomeEnabled = false
    @AppStorage(NotificationService.welcomeHomeEnabledKey) private var welcomeHomeEnabled = false
    @State private var notificationAuthStatus: UNAuthorizationStatus = .notDetermined
    @State var photoAuthStatus: PHAuthorizationStatus = .notDetermined
    @State var calendarAuthStatus: EKAuthorizationStatus = .notDetermined

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

    /// Persistent running state blocks destructive actions; background import outlives transient UI flags.
    var isImportRunning: Bool {
        importStates.contains { $0.status == .running }
    }

    var body: some View {
        settingsListCore
        .sheet(isPresented: Binding<Bool>(
            get: { exportFileURL != nil },
            set: { if !$0 {
                // Delete the precise-location temporary export when sharing is dismissed.
                if let url = exportFileURL {
                    try? FileManager.default.removeItem(at: url)
                }
                exportFileURL = nil
            } }
        )) {
            if let url = exportFileURL {
                ActivityViewSheet(fileURL: url)
            }
        }
        .fileImporter(
            isPresented: $showTripImportPicker,
            allowedContentTypes: [.json]
        ) { result in
            switch result {
            case .success(let url):
                Task { await prepareTripImport(from: url) }
            case .failure(let error):
                tripImportErrorMessage = error.localizedDescription
            }
        }
        .alert(externalImportIsGPX ? LocalizedStringKey("Import Complete") : LocalizedStringKey("Timeline Import Complete"), isPresented: Binding<Bool>(
            get: { timelineImportResultMessage != nil },
            set: { if !$0 { timelineImportResultMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if let message = timelineImportResultMessage {
                Text(message)
            }
        }
        .alert(externalImportIsGPX ? LocalizedStringKey("Import Failed") : LocalizedStringKey("Timeline Import Failed"), isPresented: Binding<Bool>(
            get: { timelineImportErrorMessage != nil },
            set: { if !$0 { timelineImportErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if let message = timelineImportErrorMessage {
                Text(message)
            }
        }
        .alert("Import Trips?", isPresented: $showTripImportConfirmation) {
            Button("Import") {
                if let pending = pendingTripImport {
                    pendingTripImport = nil
                    Task {
                        await performTripImport(
                            payload: pending.payload, fingerprint: pending.fingerprint
                        )
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingTripImport = nil }
        } message: {
            if let pending = pendingTripImport {
                Text(tripImportConfirmationText(
                    for: pending.preview, crossDeviceRepeat: pending.crossDeviceRepeat
                ))
            }
        }
        .alert("Import Complete", isPresented: Binding<Bool>(
            get: { tripImportResultMessage != nil },
            set: { if !$0 { tripImportResultMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if let message = tripImportResultMessage {
                Text(message)
            }
        }
        .alert("Import Failed", isPresented: Binding<Bool>(
            get: { tripImportErrorMessage != nil },
            set: { if !$0 { tripImportErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if let message = tripImportErrorMessage {
                Text(message)
            }
        }
        .alert(String(localized: "settings.title-regeneration.alert-title", defaultValue: "Trip Title Regeneration", comment: "Title of the trip-title regeneration result alert."), isPresented: Binding<Bool>(
            get: { titleRegenerationResultMessage != nil },
            set: { if !$0 { titleRegenerationResultMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if let message = titleRegenerationResultMessage {
                Text(message)
            }
        }
        .onAppear {
            refreshAuthorizationStatuses()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // Mirror the live PhotoKit status into both this view's local
            // state AND `PhotoService.shared.authorizationStatus` — the latter
            // gates every photo fetch, so a stale value silently empties trip
            // galleries until the next scenePhase event.
            refreshAuthorizationStatuses()
        }
        // Recount the Enhance History backlog on appearance and trip-store changes.
        .task(id: StoreChangeTracker.shared.token(for: .trip)) {
            refreshEnhanceBacklog()
        }
    }

    /// Split the modifier chain to stay within the Swift type-checker’s budget.
    private var settingsListCore: some View {
        List {
            iCloudSection
            notificationsSection
            photosSection
            calendarSection
            weatherSection
            #if DEBUG
            memoriesSection
            #else
            if !yearWrappedEntries.isEmpty {
                memoriesSection
            }
            #endif
            diagnosticsSection
            homesSection
            TemporaryHomesSettingsSection()
            routinePlacesSection
            photoImportSection
            dataSection
            appleIntelligenceSection
            aboutSection
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showAddHome) {
            HomeFormSheet(mode: .add)
        }
        .sheet(isPresented: $showAddRoutinePlace) {
            RoutinePlaceFormSheet(mode: .add)
        }
        .sheet(item: $homeToEdit) { home in
            HomeFormSheet(mode: .edit(home))
        }
        .sheet(item: $routinePlaceToEdit) { place in
            RoutinePlaceFormSheet(mode: .edit(place))
        }
        .sheet(isPresented: $showPrivacyPolicy) {
            NavigationStack {
                PrivacyPolicyWebView()
                    .navigationTitle(privacyPolicyTitle)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showPrivacyPolicy = false }
                        }
                    }
            }
        }
        .alert("Delete All Data", isPresented: $showDeleteConfirmation) {
            Button("Delete Everything", role: .destructive) { Task { await deleteAllData() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(String(localized: "settings.delete-all.message", defaultValue: "This will permanently delete all pings, stays, trips, hex visits, year memories, detected upcoming trips, and your earlier-travels country checklist (on every synced device). Your homes, temporary homes and routine places will be kept. This cannot be undone.", comment: "Delete All Data confirmation message: what is deleted and what is kept."))
        }
        .alert(
            "Couldn't Create Wrapped",
            isPresented: Binding<Bool>(
                get: { wrappedGenerationFailureMessage != nil },
                set: { if !$0 { wrappedGenerationFailureMessage = nil } }
            ),
            presenting: wrappedGenerationFailureMessage
        ) { _ in
            Button("OK", role: .cancel) { wrappedGenerationFailureMessage = nil }
        } message: { message in
            Text(message)
        }
        .alert("Export Failed", isPresented: $showExportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Could not export trip data. Please try again.")
        }
        .alert("Delete Incomplete", isPresented: $showDeleteError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Some data could not be deleted. Please try Delete All Data again.")
        }
        .alert("Discard Imported Data", isPresented: $showDiscardImportConfirmation) {
            Button("Discard", role: .destructive) { Task { await discardImport() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All trips and stays reconstructed from photos will be removed. Live-tracked data is preserved.")
        }
        .alert("Photo Import Error", isPresented: $showImportError, presenting: importErrorMessage) { _ in
            if canStartFreshAfterImportError {
                Button(String(localized: "settings.photo-import.action.start-fresh", defaultValue: "Start fresh import")) {
                    Task { await startImport() }
                }
            }
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .alert("Restart Required", isPresented: $showRestartAlert) {
            Button("OK") {
                iCloudSyncEnabled = pendingSyncToggleValue
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if pendingSyncToggleValue {
                Text("Enabling iCloud sync requires closing and reopening the app. Your data will begin syncing after you relaunch.")
            } else {
                Text("Disabling iCloud sync requires closing and reopening the app. Your data will remain on this device.")
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
        #if DEBUG
        .alert("Force Regenerate Wrapped?", isPresented: $showForceRegenerateAlert) {
            Button("Delete & Regenerate", role: .destructive) { forceRegenerateCurrentYear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes the existing \(String(currentYear)) Wrapped and creates a new one from current data. With iCloud sync on, this propagates to all your devices.")
        }
        #endif
    }

    // MARK: - Notifications Section

    @ViewBuilder
    private var notificationsSection: some View {
        Section {
            switch notificationAuthStatus {
            case .denied:
                VStack(alignment: .leading, spacing: 4) {
                    Label("Notifications Disabled", systemImage: "bell.slash")
                        .font(.subheadline.bold())
                        .foregroundStyle(.red)
                    Text("Enable notifications in Settings to receive travel alerts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }

            case .authorized, .provisional, .ephemeral:
                Toggle("Country Welcome", isOn: $countryWelcomeEnabled)
                Toggle("Welcome Home", isOn: $welcomeHomeEnabled)

            default:
                Button("Continue") {
                    Task {
                        let granted = await NotificationService.requestAuthorization()
                        if granted {
                            notificationAuthStatus = .authorized
                            countryWelcomeEnabled = true
                            welcomeHomeEnabled = true
                        } else {
                            let settings = await UNUserNotificationCenter.current().notificationSettings()
                            notificationAuthStatus = settings.authorizationStatus
                        }
                    }
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Country Welcome notifies you when you arrive in a foreign country. Welcome Home notifies you when you return from a trip lasting at least one day.")
        }
    }

    // MARK: - Photos Section

    @ViewBuilder
    private var photosSection: some View {
        Section {
            switch photoAuthStatus {
            case .authorized:
                Label("Full Access", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline)

            case .limited:
                VStack(alignment: .leading, spacing: 4) {
                    Label("Limited Access", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.subheadline.bold())
                    Text("Only selected photos will be matched to trips. Grant full access in Settings for best results.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button(String(
                    localized: "settings.photos.manage-selected",
                    defaultValue: "Manage Selected Photos",
                    comment: "Settings button that opens the limited Photos library picker."
                )) {
                    presentLimitedPhotoLibraryPicker()
                }

                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }

            case .denied:
                VStack(alignment: .leading, spacing: 4) {
                    Label("Photo Access Denied", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.subheadline.bold())
                    Text("Enable photo access in Settings to see trip photos.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }

            case .restricted:
                Label("Photo Access Restricted", systemImage: "lock.fill")
                    .foregroundStyle(.red)
                    .font(.subheadline)

            default:
                Button("Continue") {
                    Task {
                        let status = await PhotoService.shared.requestAuthorization()
                        photoAuthStatus = status
                    }
                }
            }
        } header: {
            Text("Photos")
        } footer: {
            Text(String(localized: "settings.photos.footer", defaultValue: "Travel Log matches your photos to trips using timestamps and GPS locations. It only reads them on this device and never uploads or changes them. iCloud Photos may download photos from Apple to show them.", comment: "Settings Photos section footer explaining how photos are used."))
        }
    }

    private func presentLimitedPhotoLibraryPicker() {
        guard let rootViewController = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .filter({ $0.activationState == .foregroundActive })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController else { return }

        PHPhotoLibrary.shared().presentLimitedLibraryPicker(
            from: presentingViewController(from: rootViewController))
    }

    private func presentingViewController(
        from viewController: UIViewController
    ) -> UIViewController {
        if let presented = viewController.presentedViewController {
            return presentingViewController(from: presented)
        }
        if let navigation = viewController as? UINavigationController,
           let visible = navigation.visibleViewController {
            return presentingViewController(from: visible)
        }
        if let tabs = viewController as? UITabBarController,
           let selected = tabs.selectedViewController {
            return presentingViewController(from: selected)
        }
        return viewController
    }

    // MARK: - Calendar Section (V14)

    @AppStorage(CalendarEnricher.thinHistoryAccountKey)
    var thinHistoryAccount: String = ""
    @AppStorage(CalendarEnricher.thinHistoryTipDismissedKey)
    var thinHistoryTipDismissed: Bool = false
    @AppStorage(CalendarEnricher.selectionUnavailableKey)
    var calendarSelectionUnavailable: Bool = false

    @State var isMatchingCalendarTrips = false
    @State var calendarMatchResultMessage: String?
    @State var calendarMatchFailed = false
    @State var isDetectingFlights = false
    @State var flightDetectResultMessage: String?
    @State var flightDetectFailed = false
    @State var showDeleteCalendarDataConfirmation = false
    @State var isDeletingCalendarData = false
    @State var calendarDeleteErrorMessage: String?

    private func refreshEnhanceBacklog() {
        let predicate = #Predicate<Trip> { $0.classifiedByAI == false && $0.userEdited == false }
        enhanceBacklogCount = (try? modelContext.fetchCount(FetchDescriptor<Trip>(predicate: predicate))) ?? 0
    }

    /// Re-reads the photo, calendar and notification authorization statuses.
    private func refreshAuthorizationStatuses() {
        PhotoService.shared.refreshAuthorizationStatus()
        photoAuthStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        calendarAuthStatus = CalendarEnricher.authorizationStatus
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            NotificationService.enableDefaultFeaturesIfAuthorized(
                settings.authorizationStatus)
            notificationAuthStatus = settings.authorizationStatus
        }
    }

    // MARK: - Memories Section (V11)

    @Query(sort: \YearWrapped.year, order: .reverse)
    private var yearWrappedEntries: [YearWrapped]

    @State private var isGeneratingCurrentYearWrapped: Bool = false

    #if DEBUG
    @State private var showForceRegenerateAlert = false
    @State private var isForceRegenerating = false
    #endif

    private var currentYear: Int {
        Self.wrappedYear(at: .now)
    }

    static func wrappedYear(at date: Date, timeZone: TimeZone = .current) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.component(.year, from: date)
    }

    private var currentYearWrapped: YearWrapped? {
        yearWrappedEntries.first(where: { $0.year == currentYear })
    }

    @ViewBuilder
    private var memoriesSection: some View {
        Section {
            ForEach(yearWrappedEntries) { entry in
                Button {
                    WrappedPresenter.shared.requestYear(entry.year)
                } label: {
                    HStack {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.purple)
                        Text("\(String(entry.year)) Wrapped")
                            .foregroundStyle(.primary)
                        Spacer()
                        if entry.viewedAt == nil {
                            Text("New")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.purple, in: .capsule)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if currentYearWrapped == nil {
                Button {
                    generateCurrentYearWrapped()
                } label: {
                    HStack {
                        if isGeneratingCurrentYearWrapped {
                            ProgressView().controlSize(.small)
                            Text("Generating \(String(currentYear)) Wrapped…")
                                .foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "wand.and.stars")
                            Text("Generate \(String(currentYear)) Wrapped")
                        }
                    }
                }
                .disabled(isAnyOperationRunning)
            }

            #if DEBUG
            Button(role: .destructive) {
                showForceRegenerateAlert = true
            } label: {
                HStack {
                    if isForceRegenerating {
                        ProgressView().controlSize(.small)
                        Text("Regenerating \(String(currentYear)) Wrapped…")
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "ladybug.fill")
                        Text("Force Regenerate \(String(currentYear)) (DEBUG)")
                    }
                }
            }
            .disabled(isAnyOperationRunning)
            #endif
        } header: {
            Text("Memories")
        } footer: {
            if yearWrappedEntries.isEmpty && currentYearWrapped == nil {
                Text("Your annual travel recap. \(String(currentYear))'s edition unlocks automatically on December 1, or generate it now.")
            } else {
                Text(String(localized: "settings.wrapped.snapshot-footer", defaultValue: "Tap any year to revisit. Privacy deletions can update saved recaps."))
            }
        }
    }

    private func generateCurrentYearWrapped() {
        isGeneratingCurrentYearWrapped = true
        let year = currentYear
        Task {
            // Gate the generator’s separate-context writes against Delete All; the gate publishes yearWrapped changes.
            let outcome = await PipelineGate.shared.runReturning(touching: [.yearWrapped]) {
                await AppDelegate.yearWrappedGenerator.generateIfNeeded(forYear: year)
            }
            isGeneratingCurrentYearWrapped = false
            // Present from the generator’s verdict because the main-context query can lag its separate-context save.
            // Only a committed row presents; a failed read or save is not reported as too little travel.
            switch outcome {
            case .existing, .created:
                WrappedPresenter.shared.requestYear(year)
            case .insufficientData:
                wrappedGenerationFailureMessage = String(
                    localized: "settings.wrapped.generation-failure.insufficient-data",
                    defaultValue: "There isn't enough travel recorded in \(year, format: .number.grouping(.never)) yet to build a Wrapped.",
                    comment: "Failure message when the requested year has too little travel data for a Wrapped; the argument is the year."
                )
            case .busy, .failed:
                wrappedGenerationFailureMessage = String(
                    localized: "common.save-error.try-again",
                    defaultValue: "Couldn't save. Try again",
                    comment: "Shared alert title after a user-authoritative save fails."
                )
            }
        }
    }

    #if DEBUG
    private func forceRegenerateCurrentYear() {
        isForceRegenerating = true
        let year = currentYear
        Task {
            // Gate deletion against concurrent generation.
            let regenerated = await PipelineGate.shared.runReturning(touching: [.yearWrapped]) {
                await AppDelegate.yearWrappedGenerator.forceRegenerate(forYear: year)
            }
            isForceRegenerating = false
            if regenerated {
                WrappedPresenter.shared.requestYear(year)
            } else {
                wrappedGenerationFailureMessage = String(
                    localized: "common.save-error.try-again",
                    defaultValue: "Couldn't save. Try again",
                    comment: "Shared alert title after a user-authoritative save fails."
                )
            }
        }
    }
    #endif

    // MARK: - Weather Section (V11)

    // Bind temperature to iCloud KVS, the SAME store UnitsFormatter.TemperaturePreference.current reads.
    @State private var temperatureUnitRaw: String =
        NSUbiquitousKeyValueStore.default.string(forKey: "temperatureUnit") ?? "locale"

    @ViewBuilder
    private var weatherSection: some View {
        Section {
            Picker("Temperature", selection: $temperatureUnitRaw) {
                Text("Locale Default").tag("locale")
                Text("Celsius (°C)").tag("celsius")
                Text("Fahrenheit (°F)").tag("fahrenheit")
            }
            .onChange(of: temperatureUnitRaw) { _, newValue in
                NSUbiquitousKeyValueStore.default.set(newValue, forKey: "temperatureUnit")
                NSUbiquitousKeyValueStore.default.synchronize()
            }
            .onAppear {
                // Refresh KVS changes made by another device.
                temperatureUnitRaw = NSUbiquitousKeyValueStore.default.string(forKey: "temperatureUnit") ?? "locale"
            }

            WeatherAttributionFootnote()
        } header: {
            Text("Weather")
        } footer: {
            Text("Weather data is fetched for each stay after it ends. Stays before August 2021 have no weather data available.")
        }
    }

    // MARK: - iCloud Section

    @ViewBuilder
    private var iCloudSection: some View {
        Section {
            Toggle("iCloud Sync", isOn: Binding(
                get: { iCloudSyncEnabled },
                set: { newValue in
                    pendingSyncToggleValue = newValue
                    showRestartAlert = true
                }
            ))

            if !lastCloudKitError.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last sync error:")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                    Text(lastCloudKitError)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("iCloud")
        } footer: {
            if iCloudSyncEnabled {
                Text("Your travel data syncs across all devices signed into the same iCloud account.")
            } else {
                Text("Enable to sync your travel data across all your devices via iCloud.")
            }
        }
    }

    // MARK: - Diagnostics Section

    @ViewBuilder
    private var diagnosticsSection: some View {
        Section {
            NavigationLink {
                StatusDashboardView()
            } label: {
                Label("Tracking Status", systemImage: "antenna.radiowaves.left.and.right")
            }

            NavigationLink {
                StaysListView()
            } label: {
                Label("All Stays", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
            }

            #if DEBUG
            // DEBUG exposes home-learning, confidence, FM status, and diagnostics export for device verification.
            NavigationLink {
                DebugDiagnosticsView()
            } label: {
                Label("Debug Diagnostics", systemImage: "wrench.and.screwdriver")
            }
            #endif
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("View the tracking health dashboard and raw stay data for debugging.")
        }
    }

    // MARK: - Homes Section

    @ViewBuilder
    private var homesSection: some View {
        Section {
            if homes.isEmpty {
                Text("No homes configured. Add one so Travel Log can distinguish trips from daily life.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(homes, id: \.persistentModelID) { home in
                Button {
                    homeToEdit = home
                } label: {
                    HomeRow(home: home)
                }
                .tint(.primary)
            }
            .onDelete(perform: deleteHomes)

            Button("Add Home") {
                showAddHome = true
            }

            // Expose home membership and set-aside outings so users can repair suppressed excursions.
            NavigationLink {
                HomeAreaPlacesView()
            } label: {
                Label("Home Area Places", systemImage: "map")
            }
            NavigationLink {
                NearHomeActivityView()
            } label: {
                Label("Near-Home Activity", systemImage: "figure.walk")
            }
        } header: {
            Text("Homes")
        } footer: {
            Text(String(localized: "settings.homes.footer", defaultValue: "Tap to edit. Swipe to delete. You can keep more than one home, like a second home. Time at any home counts as home, and arriving at one ends a trip. For a few months of study or work somewhere else, add a temporary home below. A vacation house you only visit occasionally is better left unregistered, so those visits stay trips.", comment: "Footer of the Homes section in Settings."))
        }
        .alert("Travel Log Needs a Home", isPresented: $showLastHomeAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Trips are what happen between stays at home, so at least one home must remain. Moving? Add your new home first (or edit this one in place), then delete the old one.")
        }
    }

    // MARK: - Routine Places Section

    @ViewBuilder
    private var routinePlacesSection: some View {
        Section {
            if routinePlaces.isEmpty {
                Text("No routine places. Add places you visit regularly that shouldn't count as trips.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(routinePlaces, id: \.persistentModelID) { place in
                Button {
                    routinePlaceToEdit = place
                } label: {
                    RoutinePlaceRow(place: place)
                }
                .tint(.primary)
            }
            .onDelete(perform: deactivateRoutinePlaces)

            Button("Add Routine Place") {
                showAddRoutinePlace = true
            }
        } header: {
            Text("Routine Places")
        } footer: {
            Text("Tap to edit. Swipe to remove.")
        }
    }

    // MARK: - Apple Intelligence Section

    @ViewBuilder
    private var appleIntelligenceSection: some View {
        let state = FMCapability.current
        Section {
            Label {
                Text(aiStatusTitle(state))
            } icon: {
                Image(systemName: aiStatusIcon(state))
                    .foregroundStyle(aiStatusColor(state))
            }
            .font(.subheadline)

            if state == .disabledByUser {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Open Settings", systemImage: "arrow.up.forward.app")
                }
            }
        } header: {
            Text("Apple Intelligence")
        } footer: {
            Text(aiStatusFooter(state))
        }
    }

    private func aiStatusTitle(_ state: FMCapabilityState) -> String {
        switch state {
        case .available: return String(localized: "settings.apple-intelligence.status.active", defaultValue: "Active", comment: "Apple Intelligence status title when it is active.")
        case .waitingForModel: return String(localized: "settings.apple-intelligence.status.downloading", defaultValue: "Downloading…", comment: "Apple Intelligence status title while its model downloads.")
        case .disabledByUser: return String(localized: "settings.apple-intelligence.status.turned-off", defaultValue: "Turned Off", comment: "Apple Intelligence status title when the user turned it off.")
        case .ineligible: return String(localized: "settings.apple-intelligence.status.not-supported", defaultValue: "Not Supported", comment: "Apple Intelligence status title on unsupported devices.")
        case .unknownUnavailable: return String(localized: "settings.apple-intelligence.status.unavailable", defaultValue: "Unavailable", comment: "Apple Intelligence status title when it is temporarily unavailable for another reason.")
        }
    }

    private func aiStatusIcon(_ state: FMCapabilityState) -> String {
        switch state {
        case .available: return "sparkles"
        case .waitingForModel: return "arrow.down.circle"
        case .disabledByUser: return "exclamationmark.circle"
        case .ineligible: return "xmark.circle"
        case .unknownUnavailable: return "questionmark.circle"
        }
    }

    private func aiStatusColor(_ state: FMCapabilityState) -> Color {
        switch state {
        case .available: return .green
        case .waitingForModel: return .blue
        case .disabledByUser: return .orange
        case .ineligible: return .secondary
        case .unknownUnavailable: return .secondary
        }
    }

    private func aiStatusFooter(_ state: FMCapabilityState) -> String {
        switch state {
        case .available:
            return String(localized: "settings.apple-intelligence.footer.active", defaultValue: "Powers AI trip titles and natural-language search.", comment: "Settings footer describing active Apple Intelligence features.")
        case .waitingForModel:
            return String(localized: "settings.apple-intelligence.footer.downloading", defaultValue: "Apple Intelligence is finishing its download. AI titles and search turn on automatically once it's ready.", comment: "Settings footer while the Apple Intelligence model downloads.")
        case .disabledByUser:
            return String(localized: "settings.apple-intelligence.footer.turned-off", defaultValue: "Turn on Apple Intelligence in Settings to enable AI titles and search.", comment: "Settings footer when Apple Intelligence is turned off.")
        case .ineligible:
            return String(localized: "settings.apple-intelligence.footer.not-supported", defaultValue: "Not supported on this iPhone. Travel Log still records and organizes all your travel.", comment: "Settings footer on devices that do not support Apple Intelligence.")
        case .unknownUnavailable:
            return String(localized: "settings.apple-intelligence.footer.unavailable", defaultValue: "Currently unavailable. AI features resume automatically when it's back.", comment: "Settings footer when Apple Intelligence is temporarily unavailable.")
        }
    }

    // MARK: - About Section

    /// Attribution surface for the bundled open datasets. GeoNames (CC BY 4.0)
    /// and OpenStreetMap (ODbL) REQUIRE attribution in the shipped product —
    /// see `DataSourcesView`.
    @ViewBuilder
    private var aboutSection: some View {
        Section {
            NavigationLink {
                DataSourcesView()
            } label: {
                Label("Data Sources & Acknowledgements", systemImage: "books.vertical")
            }

            Button {
                showPrivacyPolicy = true
            } label: {
                Label {
                    Text(privacyPolicyTitle)
                } icon: {
                    Image(systemName: "hand.raised")
                }
            }
            .foregroundStyle(.primary)
        } header: {
            Text("About")
        } footer: {
            Text("TravelLog's offline geocoder, country shapes, and airport data are built from the open datasets credited here.")
        }
    }

    private var privacyPolicyTitle: String {
        String(
            localized: "settings.about.privacy-policy",
            defaultValue: "Privacy Policy",
            comment: "Settings About row and privacy policy sheet title."
        )
    }

}

// MARK: - Home Row

private struct HomeRow: View {
    let home: Home

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(home.displayLabel())
                    .font(.subheadline.bold())
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if let locality = home.locality,
               let country = localizedCountryName(
                   iso: home.isoCountryCode,
                   fallback: home.country
               ) {
                Text("\(locality), \(country)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let country = localizedCountryName(
                iso: home.isoCountryCode,
                fallback: home.country
            ) {
                Text(country)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Routine Place Row

private struct RoutinePlaceRow: View {
    let place: RoutinePlace

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(place.label)
                    .font(.subheadline.bold())
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Text("\(place.latitude, specifier: "%.4f"), \(place.longitude, specifier: "%.4f") · \(UnitsFormatter.formatRoutineRadius(place.radiusMeters)) radius")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Privacy Policy

private struct PrivacyPolicyWebView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        if let fileURL = Bundle.main.url(forResource: "PrivacyPolicy", withExtension: "html") {
            webView.loadFileURL(
                fileURL,
                allowingReadAccessTo: fileURL.deletingLastPathComponent()
            )
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            guard !url.isFileURL else {
                decisionHandler(.allow)
                return
            }
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        }
    }
}

// MARK: - Activity View Sheet (Share)

/// Wraps UIActivityViewController for sharing exported files.
private struct ActivityViewSheet: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

