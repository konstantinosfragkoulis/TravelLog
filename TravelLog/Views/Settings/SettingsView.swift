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
import WidgetKit
import WebKit
import os.log

/// Settings screen: tracking and sync, permissions, places, preferences,
/// memories, and links to the Calendar, Import & Export and Maintenance screens.
struct SettingsView: View {
    @Query(sort: \Home.startedAt, order: .reverse) private var allHomes: [Home]
    @Query(sort: \RoutinePlace.label) private var allRoutinePlaces: [RoutinePlace]

    /// Only show current homes (not ended) in the settings list.
    var homes: [Home] { allHomes.filter(\.isCurrent) }

    /// Only show current, active routine places in the settings list.
    var routinePlaces: [RoutinePlace] { allRoutinePlaces.filter(\.isCurrent) }
    @Environment(\.modelContext) private var modelContext

    /// Operation, permission and capability state shared with the pushed
    /// Calendar, Import & Export and Maintenance screens.
    @State private var model = SettingsModel()

    @State private var showAddHome = false
    @State var showLastHomeAlert = false
    @State private var showAddRoutinePlace = false
    @State private var homeToEdit: Home?
    @State private var routinePlaceToEdit: RoutinePlace?
    @State var saveFailed = false
    /// Explain why Wrapped generation returned no row.
    @State private var wrappedGenerationFailureMessage: String?

    @AppStorage(AppDelegate.iCloudSyncEnabledKey) var iCloudSyncEnabled = false
    @AppStorage(AppDelegate.lastCloudKitErrorKey) private var lastCloudKitError = ""
    @State private var showRestartAlert = false
    @State private var pendingSyncToggleValue = false
    @State private var showPrivacyPolicy = false

    @AppStorage(NotificationService.countryWelcomeEnabledKey) private var countryWelcomeEnabled = false
    @AppStorage(NotificationService.welcomeHomeEnabledKey) private var welcomeHomeEnabled = false
    @AppStorage(CalendarEnricher.selectionUnavailableKey)
    private var calendarSelectionUnavailable: Bool = false

    var body: some View {
        settingsListCore
        .onAppear {
            Task { await model.refreshAuthorizationStatuses() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // Mirror the live PhotoKit status into both the shared state AND
            // `PhotoService.shared.authorizationStatus`; the latter gates
            // every photo fetch, so a stale value silently empties trip
            // galleries until the next scenePhase event.
            Task { await model.refreshAuthorizationStatuses() }
        }
    }

    /// Split the modifier chain to stay within the Swift type-checker’s budget.
    private var settingsListCore: some View {
        List {
            trackingAndSyncSection
            permissionsSection
            homesSection
            TemporaryHomesSettingsSection()
            routinePlacesSection
            preferencesSection
            #if DEBUG
            memoriesSection
            #else
            if !yearWrappedEntries.isEmpty {
                memoriesSection
            }
            #endif
            dataSection
            aboutSection
        }
        .headerProminence(.increased)
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

    // MARK: - Tracking & Sync Section

    @ViewBuilder
    private var trackingAndSyncSection: some View {
        Section {
            NavigationLink {
                StatusDashboardView()
            } label: {
                Label("Tracking Status", systemImage: "antenna.radiowaves.left.and.right")
            }

            Toggle(isOn: Binding(
                get: { iCloudSyncEnabled },
                set: { newValue in
                    pendingSyncToggleValue = newValue
                    showRestartAlert = true
                }
            )) {
                Label("iCloud Sync", systemImage: "icloud")
            }

            if !lastCloudKitError.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last sync error:")
                        .font(.caption.bold())
                        .foregroundStyle(AppTheme.failure)
                    Text(lastCloudKitError)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(String(
                localized: "settings.section.tracking-sync",
                defaultValue: "Tracking & Sync",
                comment: "Header of the Settings section holding Tracking Status and the iCloud Sync toggle."
            ))
        } footer: {
            Text(String(
                localized: "settings.icloud.footer",
                defaultValue: "iCloud Sync shares your travel data across devices on the same iCloud account.",
                comment: "Footer of the Settings Tracking & Sync section explaining iCloud Sync."
            ))
        }
    }

    // MARK: - Permissions Section

    @ViewBuilder
    private var permissionsSection: some View {
        Section {
            notificationRows
            photoRows
            NavigationLink {
                CalendarSettingsView(model: model)
            } label: {
                LabeledContent {
                    calendarStatusValue
                } label: {
                    Label("Calendar", systemImage: "calendar")
                }
            }
        } header: {
            Text(String(
                localized: "settings.section.permissions",
                defaultValue: "Permissions",
                comment: "Header of the Settings section for notification, photo and calendar access."
            ))
        } footer: {
            Text(String(localized: "settings.photos.footer", defaultValue: "Travel Log matches your photos to trips using timestamps and GPS locations. It only reads them on this device and never uploads or changes them. iCloud Photos may download photos from Apple to show them.", comment: "Settings Photos section footer explaining how photos are used."))
        }
    }

    @ViewBuilder
    private var notificationRows: some View {
        switch model.notificationAuthStatus {
        case .denied:
            VStack(alignment: .leading, spacing: 4) {
                Label("Notifications Disabled", systemImage: "bell.slash")
                    .font(.subheadline.bold())
                    .foregroundStyle(AppTheme.attention)
                Text("Enable notifications in Settings to receive travel alerts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Open Settings") { SettingsModel.openSystemSettings() }

        case .authorized, .provisional, .ephemeral:
            Toggle(isOn: $countryWelcomeEnabled) {
                SettingsRowText(
                    title: String(localized: "Country Welcome"),
                    caption: String(
                        localized: "settings.notifications.country-welcome.caption",
                        defaultValue: "When you arrive in another country",
                        comment: "Caption under the Country Welcome notification toggle in Settings."
                    ))
            }
            Toggle(isOn: $welcomeHomeEnabled) {
                SettingsRowText(
                    title: String(localized: "Welcome Home"),
                    caption: String(
                        localized: "settings.notifications.welcome-home.caption",
                        defaultValue: "When you return from a trip of a day or more",
                        comment: "Caption under the Welcome Home notification toggle in Settings."
                    ))
            }

        default:
            Button {
                Task {
                    let granted = await NotificationService.requestAuthorization()
                    if granted {
                        model.notificationAuthStatus = .authorized
                        countryWelcomeEnabled = true
                        welcomeHomeEnabled = true
                    } else {
                        let settings = await UNUserNotificationCenter.current().notificationSettings()
                        model.notificationAuthStatus = settings.authorizationStatus
                    }
                }
            } label: {
                PermissionRequestLabel(title: String(localized: "Notifications"), systemImage: "bell")
            }
        }
    }

    @ViewBuilder
    private var photoRows: some View {
        switch model.photoAuthStatus {
        case .authorized:
            LabeledContent {
                Text("Full Access")
                    .foregroundStyle(.secondary)
            } label: {
                Label("Photos", systemImage: "photo.on.rectangle")
            }

        case .limited:
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent {
                    Text("Limited Access")
                        .foregroundStyle(AppTheme.attention)
                } label: {
                    Label("Photos", systemImage: "photo.on.rectangle")
                }
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

            Button("Open Settings") { SettingsModel.openSystemSettings() }

        case .denied:
            VStack(alignment: .leading, spacing: 4) {
                Label("Photo Access Denied", systemImage: "xmark.circle.fill")
                    .foregroundStyle(AppTheme.attention)
                    .font(.subheadline.bold())
                Text("Enable photo access in Settings to see trip photos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Open Settings") { SettingsModel.openSystemSettings() }

        case .restricted:
            Label("Photo Access Restricted", systemImage: "lock.fill")
                .foregroundStyle(AppTheme.attention)
                .font(.subheadline)

        default:
            Button {
                Task {
                    model.photoAuthStatus = await PhotoService.shared.requestAuthorization()
                }
            } label: {
                PermissionRequestLabel(title: String(localized: "Photos"), systemImage: "photo.on.rectangle")
            }
        }
    }

    @ViewBuilder
    private var calendarStatusValue: some View {
        switch model.calendarAuthStatus {
        case nil:
            EmptyView()
        case .fullAccess:
            if calendarSelectionUnavailable {
                Text(String(
                    localized: "settings.calendar.selection-unavailable",
                    defaultValue: "None available",
                    comment: "Secondary value on the Settings Calendars row when none of the calendars the user checked is available on this device."
                ))
                .foregroundStyle(AppTheme.attention)
            } else {
                Text("Connected")
            }
        case .writeOnly:
            Text("Add-Only Access")
                .foregroundStyle(AppTheme.attention)
        case .denied:
            // Needs the user's action: orange, with the attention glyph.
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.circle.fill")
                    .accessibilityHidden(true)
                Text(String(
                    localized: "settings.permission.status.denied",
                    defaultValue: "Denied",
                    comment: "Value on a Settings permission row when the user denied access."
                ))
            }
            .foregroundStyle(AppTheme.attention)
        case .restricted:
            Text(String(
                localized: "settings.permission.status.restricted",
                defaultValue: "Restricted",
                comment: "Value on a Settings permission row when access is restricted on this device."
            ))
            .foregroundStyle(AppTheme.attention)
        default:
            Text(String(
                localized: "settings.permission.status.not-set-up",
                defaultValue: "Not Set Up",
                comment: "Value on a Settings permission row when access has not been requested yet."
            ))
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

    // MARK: - Memories Section (V11)

    @Query(sort: \YearWrapped.year, order: .reverse)
    private var yearWrappedEntries: [YearWrapped]

    #if DEBUG
    @State private var showForceRegenerateAlert = false
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
            // One entry per year: retained same-id twins share an identity.
            ForEach(YearWrapped.presented(yearWrappedEntries), id: \.year) { entry in
                Button {
                    WrappedPresenter.shared.requestYear(entry.year)
                } label: {
                    HStack {
                        Image(systemName: "sparkles")
                            .foregroundStyle(AppTheme.accent)
                        Text("\(String(entry.year)) Wrapped")
                            .foregroundStyle(.primary)
                        Spacer()
                        if YearWrapped.isNew(year: entry.year, in: yearWrappedEntries) {
                            AppChip(label: Text("New"), style: .selected, small: true)
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
                        if model.isGeneratingCurrentYearWrapped {
                            ProgressView().controlSize(.small)
                            Text("Generating \(String(currentYear)) Wrapped…")
                                .foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "wand.and.stars")
                            Text("Generate \(String(currentYear)) Wrapped")
                        }
                    }
                }
                .disabled(model.isAnyOperationRunning)
            }

            #if DEBUG
            Button(role: .destructive) {
                showForceRegenerateAlert = true
            } label: {
                HStack {
                    if model.isForceRegenerating {
                        ProgressView().controlSize(.small)
                        Text("Regenerating \(String(currentYear)) Wrapped…")
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "ladybug.fill")
                        Text("Force Regenerate \(String(currentYear)) (DEBUG)")
                    }
                }
            }
            .disabled(model.isAnyOperationRunning)
            #endif
        } header: {
            Text("Memories")
        } footer: {
            if yearWrappedEntries.isEmpty && currentYearWrapped == nil {
                Text("Your annual travel recap. \(String(currentYear))'s edition unlocks automatically on December 1, or generate it now.")
            } else {
                Text(String(
                    localized: "settings.wrapped.footer",
                    defaultValue: "Privacy deletions can update saved recaps.",
                    comment: "Footer of the Settings Memories section listing saved yearly recaps."
                ))
            }
        }
    }

    private func generateCurrentYearWrapped() {
        model.isGeneratingCurrentYearWrapped = true
        let year = currentYear
        Task {
            // Gate the generator’s separate-context writes against Delete All; the gate publishes yearWrapped changes.
            let outcome = await PipelineGate.shared.runReturning(touching: [.yearWrapped]) {
                await AppDelegate.yearWrappedGenerator.generateIfNeeded(forYear: year)
            }
            model.isGeneratingCurrentYearWrapped = false
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
        model.isForceRegenerating = true
        let year = currentYear
        Task {
            // Gate deletion against concurrent generation.
            let regenerated = await PipelineGate.shared.runReturning(touching: [.yearWrapped]) {
                await AppDelegate.yearWrappedGenerator.forceRegenerate(forYear: year)
            }
            model.isForceRegenerating = false
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

    // MARK: - Preferences Section

    // Bind temperature to iCloud KVS, the SAME store UnitsFormatter.TemperaturePreference.current reads.
    @State private var temperatureUnitRaw: String =
        NSUbiquitousKeyValueStore.default.string(forKey: "temperatureUnit") ?? "locale"

    @ViewBuilder
    private var preferencesSection: some View {
        let state = model.appleIntelligence
        Section {
            LabeledContent {
                Text(aiStatusTitle(state))
                    .foregroundStyle(aiStatusColor(state))
            } label: {
                Label {
                    SettingsRowText(title: String(localized: "Apple Intelligence"), caption: aiStatusCaption(state))
                } icon: {
                    Image(systemName: aiStatusIcon(state))
                        .foregroundStyle(aiStatusIconColor(state))
                }
            }

            if state == .disabledByUser {
                Button {
                    SettingsModel.openSystemSettings()
                } label: {
                    Label("Open Settings", systemImage: "arrow.up.forward.app")
                }
            }

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
            Text(String(
                localized: "settings.section.preferences",
                defaultValue: "Preferences",
                comment: "Header of the Settings section holding Apple Intelligence status and the temperature unit."
            ))
        } footer: {
            Text(String(
                localized: "settings.weather.footer",
                defaultValue: "Weather is added to each stay after it ends, for stays from August 2021 on.",
                comment: "Footer under the temperature setting and Apple Weather attribution: when stay weather appears and how far back it goes."
            ))
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

    /// Healthy stays quiet, a download is ongoing, turned off needs the
    /// user's action.
    private func aiStatusColor(_ state: FMCapabilityState) -> Color {
        switch state {
        case .available: return .secondary
        case .waitingForModel: return AppTheme.ongoing
        case .disabledByUser: return AppTheme.attention
        case .ineligible: return .secondary
        case .unknownUnavailable: return .secondary
        }
    }

    /// The row icon wears the accent while the feature works or is coming.
    private func aiStatusIconColor(_ state: FMCapabilityState) -> Color {
        switch state {
        case .available, .waitingForModel: return AppTheme.accent
        default: return aiStatusColor(state)
        }
    }

    private func aiStatusCaption(_ state: FMCapabilityState) -> String {
        switch state {
        case .available:
            return String(localized: "settings.apple-intelligence.footer.active", defaultValue: "Powers AI trip titles and natural-language search.", comment: "Settings footer describing active Apple Intelligence features.")
        case .waitingForModel:
            return String(localized: "settings.apple-intelligence.caption.downloading", defaultValue: "AI titles and search turn on once the download finishes.", comment: "Caption under the Apple Intelligence status in Settings while its model downloads.")
        case .disabledByUser:
            return String(localized: "settings.apple-intelligence.caption.turned-off", defaultValue: "Turn it on in Settings for AI titles and search.", comment: "Caption under the Apple Intelligence status in Settings when the user turned Apple Intelligence off.")
        case .ineligible:
            return String(localized: "settings.apple-intelligence.caption.not-supported", defaultValue: "Travel Log still records and organizes all your travel.", comment: "Caption under the Not Supported Apple Intelligence status in Settings, on devices without Apple Intelligence.")
        case .unknownUnavailable:
            return String(localized: "settings.apple-intelligence.caption.unavailable", defaultValue: "AI features resume automatically when it's back.", comment: "Caption under the Unavailable Apple Intelligence status in Settings when it is temporarily unavailable.")
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
            Text(String(
                localized: "settings.homes.footer.trip-boundary",
                defaultValue: "You can have more than one home, and arriving at any of them ends a trip. Leave a vacation house you visit only now and then unregistered, so those visits stay trips.",
                comment: "Footer of the Homes section in Settings: several homes are allowed, arriving at one ends a trip, and an occasional vacation house is better left out."
            ))
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
            // The empty-state line above already explains the list.
            if !routinePlaces.isEmpty {
                Text(String(
                    localized: "settings.routine-places.footer",
                    defaultValue: "Visits to these places never count as trips.",
                    comment: "Footer of the Routine Places section in Settings, shown when at least one routine place exists."
                ))
            }
        }
    }

    // MARK: - Data Section

    @ViewBuilder
    private var dataSection: some View {
        Section {
            NavigationLink {
                SettingsImportExportView(model: model)
            } label: {
                Label(SettingsDataLinks.importExportTitle, systemImage: "arrow.up.arrow.down.square")
            }
            NavigationLink {
                SettingsMaintenanceView(model: model)
            } label: {
                Label(SettingsDataLinks.maintenanceTitle, systemImage: "wrench.adjustable")
            }
        } header: {
            Text(String(
                localized: "settings.section.data",
                defaultValue: "Data",
                comment: "Header of the Settings section linking to Import & Export and Maintenance."
            ))
        }
    }

    // MARK: - About Section

    /// Attribution surface for the bundled open datasets. GeoNames (CC BY 4.0)
    /// and OpenStreetMap (ODbL) REQUIRE attribution in the shipped product;
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

// MARK: - Row pieces

/// A row title with an optional secondary caption beneath it.
private struct SettingsRowText: View {
    let title: String
    let caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A permission that has not been requested yet: its name, then Continue.
private struct PermissionRequestLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
                .foregroundStyle(.primary)
            Spacer()
            Text("Continue")
        }
    }
}

// MARK: - Home Row

private struct HomeRow: View {
    let home: Home

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(home.displayLabel())
                    .font(.body.weight(.semibold))
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
                    .font(.body.weight(.semibold))
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
