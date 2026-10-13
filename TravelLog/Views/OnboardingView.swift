//
//  OnboardingView.swift
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

/// Multi-step onboarding flow.
///
/// Steps:
/// 1. Welcome - explain what the app does
/// 2. Location permission - request "Always" authorization, handle every edge case
/// 3. Home setup - set the user's home location via map or current location
/// 4. Routine places (optional) - add regular places that shouldn't count as trips
/// 5. iCloud sync - toggle iCloud syncing on or off
/// 6. Photo library permission - request read-only access so photos can be matched to trips
/// 7. Photo library import - offer to scan photo library and reconstruct
///    past trips. Auto-skipped when the user declined / restricted photo access on
///    the previous step.
/// 8. Notifications - explain value, request permission (Apple HIG best practice)
/// On completion - start monitoring, transition to main app
struct OnboardingView: View {

    /// Empty is the stable sentinel for the localized default Home label.
    nonisolated static let defaultHomeLabel = ""

    nonisolated static func resumeStep(saved: Int, hasHome: Bool) -> Int {
        let step = min(max(saved, 0), 7)
        return step > 2 && !hasHome ? 2 : step
    }

    private static let stepIndexKey = "onboardingStepIndex"

    @State private var currentStep: Int
    @AppStorage(Self.stepIndexKey) private var savedStep = 0
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @Query private var homes: [Home]

    /// Cross-step state. Currently only the photo-auth outcome from
    /// `PhotoPermissionStep` (read by `PhotoImportStep` to decide
    /// whether to show or auto-skip). Kept in a single observable
    /// model so future cross-step state additions don't fan out into
    /// ad-hoc `@AppStorage` reads scattered across the file.
    @State private var onboardingState = OnboardingState()

    init() {
        _currentStep = State(initialValue: Self.resumeStep(
            saved: UserDefaults.standard.integer(forKey: Self.stepIndexKey),
            hasHome: true
        ))
    }

    var body: some View {
        Group {
            switch currentStep {
            case 0: WelcomeStep(onContinue: { currentStep = 1 })
            case 1: PermissionStep(onContinue: { currentStep = 2 })
            case 2: HomeSetupStep(onComplete: { currentStep = 3 })
            case 3: RoutinePlacesStep(onComplete: { currentStep = 4 })
            case 4: ICloudSyncStep(onComplete: { currentStep = 5 })
            case 5: PhotoPermissionStep(state: onboardingState, onComplete: {
                // Skip the PhotoImportStep when the user didn't grant
                // photo access — there's nothing useful for it to do.
                // Doing the skip HERE (not inside PhotoImportStep via
                // an invisible auto-advance view) avoids a ~0.5s blank-
                // screen flash during the step 5 → 6 → 7 transition
                // animations. PhotoImportStep keeps its own
                // `shouldShowStep` check as defensive belt-and-suspenders
                // for a hypothetical auth change between this closure
                // firing and that step's body evaluating.
                let granted = onboardingState.photoAuthStatus == .authorized
                    || onboardingState.photoAuthStatus == .limited
                currentStep = granted ? 6 : 7
            })
            case 6: PhotoImportStep(state: onboardingState, onComplete: { currentStep = 7 })
            case 7: NotificationStep(onComplete: { finishOnboarding() })
            default: WelcomeStep(onContinue: { currentStep = 1 })
            }
        }
        .transition(.asymmetric(
            insertion: .move(edge: .trailing),
            removal: .move(edge: .leading)
        ))
        .animation(.easeInOut, value: currentStep)
        .onAppear {
            // Keep re-onboarding mounted after Home is saved: RootView's
            // onboardingComplete && !homes.isEmpty gate would otherwise swap
            // in MainTabView mid-flow. Only finishOnboarding() may set this true.
            onboardingComplete = false
            let resumedStep = Self.resumeStep(saved: savedStep, hasHome: !homes.isEmpty)
            if currentStep != resumedStep {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    currentStep = resumedStep
                }
            }
        }
        .onChange(of: currentStep) { _, newStep in
            savedStep = newStep
        }
    }

    private func finishOnboarding() {
        Task { @MainActor in
            LocationService.shared.startMonitoring()

            // Request a one-shot location to record the first ping immediately.
            // Without this, the user would have to wait for the next SLC event
            // (which requires a cell tower change) before any data appears.
            // The location pipeline is already connected by AppDelegate, so
            // the delegate callback will feed it through PingRecorder automatically.
            LocationService.shared.requestCurrentLocation()

            AppDelegate.scheduleBackgroundRefresh()

            savedStep = 0
            onboardingComplete = true
        }
    }
}

/// Atomic persistence boundary for onboarding's first Home. Adding a Home
/// changes every canonical title prompt, so the row insertion and title
/// invalidation must either commit together or roll back together.
@MainActor
enum OnboardingHomeSaveWorker {
    static func insert(
        _ home: Home,
        in context: ModelContext,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        let titleInputsBefore = try TripTitleStore.fetchActiveHomeTitleInputs(
            in: context)
        context.insert(home)
        do {
            _ = try TripTitleStore.invalidateAllGeneratedTitlesIfActiveHomesChanged(
                from: titleInputsBefore,
                in: context)
            try save(context)
        } catch {
            context.rollback()
            throw error
        }
        try? TripTitleStore.recordActiveHomeTitleFingerprint(in: context)
    }
}

private struct OnboardingStepScaffold<Header: View, Content: View, Actions: View>: View {
    let icon: String
    @ViewBuilder var header: Header      // headline + caption
    @ViewBuilder var content: Content    // status views, fields, toggles
    @ViewBuilder var actions: Actions    // buttons

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            VStack(spacing: 8) { header }
                .padding(.horizontal, 24)
            content
            Spacer()
            actions
                .padding(.bottom, 48)
        }
    }
}

// MARK: - Step 1: Welcome

private struct WelcomeStep: View {

    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "globe.europe.africa")
                .font(.system(size: 80))
                .foregroundStyle(.tint)

            VStack(spacing: 12) {
                Text("Travel Log")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                Text("Your travels, remembered automatically.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            VStack(alignment: .leading, spacing: 16) {
                FeatureRow(
                    icon: "battery.100percent",
                    title: String(
                        localized: "onboarding.feature.battery.title",
                        defaultValue: "Low Battery Use",
                        comment: "Onboarding feature title about low battery use."
                    ),
                    description: String(
                        localized: "onboarding.feature.battery.description",
                        defaultValue: "No constant GPS in the background",
                        comment: "Onboarding feature description explaining low battery use."
                    )
                )
                FeatureRow(
                    icon: "mappin.and.ellipse",
                    title: String(
                        localized: "onboarding.feature.automatic-trips.title",
                        defaultValue: "Automatic Trips",
                        comment: "Onboarding feature title for automatic trip organization."
                    ),
                    // Don't promise "AI" on hardware that can never run
                    // Foundation Models — the honest framing is the
                    // automatic organizing, which works everywhere.
                    description: FMCapability.current.isPermanentlyIneligible
                        ? String(
                            localized: "onboarding.feature.automatic-trips.description.without-ai",
                            defaultValue: "Your stays turn into trips on their own",
                            comment: "Onboarding automatic-trip description on devices that cannot use Apple Intelligence."
                        )
                        : String(
                            localized: "onboarding.feature.automatic-trips.description.with-ai",
                            defaultValue: "On-device AI turns your stays into trips",
                            comment: "Onboarding automatic-trip description on devices that can use Apple Intelligence."
                        )
                )
                FeatureRow(
                    icon: "hexagon",
                    title: String(
                        localized: "onboarding.feature.exploration-map.title",
                        defaultValue: "Exploration Map",
                        comment: "Onboarding feature title for the exploration map."
                    ),
                    description: String(
                        localized: "onboarding.feature.exploration-map.description",
                        defaultValue: "See how much of the world you've covered",
                        comment: "Onboarding feature description for the exploration map."
                    )
                )
            }
            .padding(.horizontal, 24)

            Spacer()

            Button("Get Started") {
                onContinue()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, 48)
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.bold())
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Step 2: Location Permission

/// Handles every `CLAuthorizationStatus` case:
///
/// - `.notDetermined`: Show the request button. After tapping, the system dialog appears.
/// - `.authorizedAlways`: Perfect - show green checkmark, proceed.
/// - `.authorizedWhenInUse`: Partial - explain "Always" is needed, offer Settings link.
/// - `.denied`: Blocked - explain, offer Settings link.
/// - `.restricted`: Parental controls / MDM - explain that the user cannot change this.
///
/// When the user returns from Settings, `sceneDidBecomeActive` fires and we re-read the
/// status via the notification posted by `LocationService`.
private struct PermissionStep: View {

    let onContinue: () -> Void

    @State private var status = LocationService.shared.authorizationStatus
    @State private var hasRequestedPermission = false
    @State private var backgroundRefreshStatus = UIApplication.shared.backgroundRefreshStatus

    var body: some View {
        OnboardingStepScaffold(icon: "location.fill") {
            Text(String(localized: "onboarding.location.title", defaultValue: "Record trips, even when the app is closed.", comment: "Onboarding location step headline."))
                .font(.title2.bold())
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
            Text(String(localized: "onboarding.location.explanation", defaultValue: "“Always” location access lets Travel Log notice trips in the background with minimal battery use. Your travel history stays on your device and in your private iCloud. Weather and some place names come from Apple services."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } content: {
            permissionStatusView
                .padding(.horizontal)

            if backgroundRefreshStatus != .available {
                backgroundRefreshWarning
                    .padding(.horizontal)
            }

        } actions: {
            actionButtons
        }
        .onAppear {
            refreshStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .locationAuthorizationChanged)) { notification in
            if let rawValue = notification.userInfo?["status"] as? Int32,
               let newStatus = CLAuthorizationStatus(rawValue: rawValue) {
                status = newStatus
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // User may have returned from Settings - re-read everything
            refreshStatus()
        }
    }

    // MARK: - Status Display

    @ViewBuilder
    private var permissionStatusView: some View {
        switch status {
        case .notDetermined:
            if hasRequestedPermission {
                // System dialog is showing or was dismissed without a choice (rare)
                Label("Waiting for your response…", systemImage: "hourglass")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            // Before request: show nothing (the button below handles it)

        case .authorizedAlways:
            Label("“Always” access granted", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.subheadline)
                .multilineTextAlignment(.center)

        case .authorizedWhenInUse:
            VStack(spacing: 8) {
                Label("Only “While Using” granted", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.subheadline.bold())
                Text(String(localized: "onboarding.location.status.when-in-use.detail", defaultValue: "Choose “Always” in Settings to record trips in the background.", comment: "Guidance under the While Using status label."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

        case .denied:
            VStack(spacing: 8) {
                Label("Location access denied", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.subheadline.bold())
                Text(String(localized: "onboarding.location.status.denied.detail", defaultValue: "Turn on location access in Settings to record trips.", comment: "Guidance under the denied status label."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

        case .restricted:
            VStack(spacing: 8) {
                Label("Location access restricted", systemImage: "lock.fill")
                    .foregroundStyle(.red)
                    .font(.subheadline.bold())
                Text("This device doesn't allow Travel Log to request location access, possibly due to parental controls or a management profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

        @unknown default:
            Label("Unknown permission state", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
                .font(.subheadline)
        }
    }

    @ViewBuilder
    private var backgroundRefreshWarning: some View {
        switch backgroundRefreshStatus {
        case .available:
            EmptyView()
        case .denied:
            VStack(spacing: 8) {
                Label("Background App Refresh is off", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.subheadline.bold())
                Text(String(localized: "onboarding.background-refresh.off.detail", defaultValue: "Turn it on in Settings so tracking keeps running when iOS closes the app.", comment: "Guidance when Background App Refresh is off."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        case .restricted:
            VStack(spacing: 8) {
                Label("Background App Refresh is restricted", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.subheadline.bold())
                Text(String(localized: "onboarding.background-refresh.restricted.detail", defaultValue: "A device policy blocks it, so tracking may stop when iOS closes the app.", comment: "Guidance when Background App Refresh is restricted."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        @unknown default:
            EmptyView()
        }
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 12) {
            switch status {
            case .notDetermined:
                Button("Continue") {
                    requestPermission()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            case .authorizedAlways:
                Button("Continue") {
                    onContinue()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            case .authorizedWhenInUse:
                Button("Open Settings") {
                    openAppSettings()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Continue") {
                    onContinue()
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

            case .denied:
                Button("Open Settings") {
                    openAppSettings()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Continue") {
                    onContinue()
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

            case .restricted:
                // User cannot change this - just let them continue
                Button("Continue") {
                    onContinue()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            @unknown default:
                Button("Continue") {
                    onContinue()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    // MARK: - Actions

    @MainActor
    private func requestPermission() {
        hasRequestedPermission = true
        // Two-step flow: request WhenInUse first. The LocationService delegate
        // auto-escalates to Always once WhenInUse is granted.
        LocationService.shared.requestWhenInUseAuthorization()
    }

    private func refreshStatus() {
        status = LocationService.shared.authorizationStatus
        backgroundRefreshStatus = UIApplication.shared.backgroundRefreshStatus
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// One presentation of the Home step's map picker. `MapLocationPicker`
/// writes live through its binding, so the draft lives in this view's own
/// state: each presentation starts from the committed coordinate, only Done
/// hands the draft back, and Cancel discards it. A late search or
/// current-location callback from a dismissed presentation can only write
/// that presentation's discarded draft.
private struct HomeMapPickerCover: View {

    let onDone: (CLLocationCoordinate2D?) -> Void
    let onCancel: () -> Void

    @State private var draft: CLLocationCoordinate2D?

    init(
        initialCoordinate: CLLocationCoordinate2D?,
        onDone: @escaping (CLLocationCoordinate2D?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onDone = onDone
        self.onCancel = onCancel
        self._draft = State(initialValue: initialCoordinate)
    }

    var body: some View {
        NavigationStack {
            MapLocationPicker(selectedCoordinate: $draft)
                .navigationTitle("Choose Home Location")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { onDone(draft) }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { onCancel() }
                    }
                }
        }
    }
}

// MARK: - Step 3: Home Setup

private struct HomeSetupStep: View {

    let onComplete: () -> Void

    @Environment(\.modelContext) private var modelContext

    @State private var label = OnboardingView.defaultHomeLabel
    @State private var selectedCoordinate: CLLocationCoordinate2D?
    @State private var showMapPicker = false
    @State private var isSaving = false
    @State private var saveErrorMessage = ""
    @State private var showSaveError = false
    @State private var pendingUnmappedHome: PendingHome?
    @State private var showUnmappedConfirmation = false

    private nonisolated struct PendingHome: Sendable {
        let label: String
        let latitude: Double
        let longitude: Double
        let locality: String?
        let administrativeArea: String?
        let country: String?
        let isoCountryCode: String?
    }

    var body: some View {
        OnboardingStepScaffold(icon: "house.fill") {
            Text(String(localized: "onboarding.home.title", defaultValue: "Set your home.", comment: "Onboarding home step headline."))
                .font(.title2.bold())
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
            Text(String(localized: "onboarding.home.caption", defaultValue: "Time at home never counts as a trip.", comment: "Onboarding home step caption."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } content: {
            VStack(spacing: 16) {
                TextField("Home name", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 32)

                if let coord = selectedCoordinate {
                    VStack(spacing: 8) {
                        Label("Home location set", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.bold())
                            .foregroundStyle(.green)
                        Text("\(coord.latitude, specifier: "%.5f"), \(coord.longitude, specifier: "%.5f")")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        RadiusMapPreview(coordinate: coord, radiusMeters: nil)
                            .padding(.horizontal, 32)
                    }
                }

                Button {
                    showMapPicker = true
                } label: {
                    Label(
                        selectedCoordinate == nil ? "Choose on Map" : "Change Location",
                        systemImage: "map"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 32)

                // No radius slider: home membership uses the measured
                // city boundary where one exists, and everywhere else a
                // small core that grows from how the user actually moves —
                // a hand-set radius has no role in either. `Home.radiusKm`
                // persists at its default purely as legacy/rollback ballast.
                HomeAreaSourcePreview(coordinate: selectedCoordinate)
                    .padding(.horizontal, 32)
            }
        } actions: {
            Button {
                saveHome()
            } label: {
                if isSaving {
                    ProgressView()
                } else {
                    Text("Continue")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(selectedCoordinate == nil || isSaving)
        }
        .fullScreenCover(isPresented: $showMapPicker) {
            HomeMapPickerCover(
                initialCoordinate: selectedCoordinate,
                onDone: { coordinate in
                    selectedCoordinate = coordinate
                    showMapPicker = false
                },
                onCancel: { showMapPicker = false }
            )
        }
        .alert("Couldn't Save Your Home", isPresented: $showSaveError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveErrorMessage)
        }
        .alert(
            unmappedHomeConfirmationText,
            isPresented: $showUnmappedConfirmation,
            presenting: pendingUnmappedHome
        ) { pending in
            Button("Save") {
                pendingUnmappedHome = nil
                persistHome(pending)
            }
            Button("Cancel", role: .cancel) {
                pendingUnmappedHome = nil
                isSaving = false
            }
        }
    }

    private var unmappedHomeConfirmationText: String {
        String(
            localized: "home.unmapped.confirmation",
            defaultValue: "This location looks unmapped or at sea. Trip detection may not recognize returns home. Save anyway?",
            comment: "Confirmation shown before saving a home whose reverse geocode found neither a locality nor an administrative area."
        )
    }

    private func saveHome() {
        guard let coord = selectedCoordinate else { return }
        isSaving = true
        let label = self.label

        Task {
            // Offline-first: `resolveWithFallback` uses MapKit (rate-limited,
            // 30/60 s, per-cell cached) only for the long tail the offline
            // data can't name, keeping first-launch Home creation off the
            // shared MKReverseGeocodingRequest budget.
            let result = await GeocodeResolver.shared.resolveWithFallback(
                latitude: coord.latitude, longitude: coord.longitude
            )
            let pending = PendingHome(
                label: label,
                latitude: coord.latitude,
                longitude: coord.longitude,
                // Country-name guard (`Result.localityForStorage`) — never
                // store the country name as the home's city.
                locality: result?.localityForStorage,
                administrativeArea: result?.administrativeArea,
                country: result?.country,
                isoCountryCode: result?.isoCountryCode
            )

            if HomeSaveDecision.requiresUnmappedConfirmation(
                locality: pending.locality,
                administrativeArea: pending.administrativeArea
            ) {
                pendingUnmappedHome = pending
                showUnmappedConfirmation = true
                return
            }

            persistHome(pending)
        }
    }

    private func persistHome(_ pending: PendingHome) {
        let home = Home(
            label: pending.label,
            latitude: pending.latitude,
            longitude: pending.longitude
        )
        home.locality = pending.locality
        home.administrativeArea = pending.administrativeArea
        home.country = pending.country
        home.isoCountryCode = pending.isoCountryCode

        // Defense in depth: onboarding only renders with zero
        // Home rows, but if a future flow change ever re-runs it
        // with homes present, inserting must be IDEMPOTENT — skip
        // when an active home already covers this spot (the same
        // 1 km rule `PlacesDeduplicator` collapses by). Never end
        // other homes here: multiple active homes are a
        // first-class state (second home / studying abroad).
        let activePredicate = #Predicate<Home> { $0.endedAt == nil }
        let actives = (try? modelContext.fetch(
            FetchDescriptor<Home>(predicate: activePredicate))) ?? []
        let newLocation = CLLocation(
            latitude: home.latitude, longitude: home.longitude)
        let duplicate = actives.contains {
            CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                .distance(from: newLocation) <= 1000
        }
        if !duplicate {
            do {
                try OnboardingHomeSaveWorker.insert(home, in: modelContext)
            } catch {
                // RootView's onboardingComplete && !homes.isEmpty gate
                // means a silently lost Home strands the next launch.
                isSaving = false
                saveErrorMessage = String(
                    localized: "onboarding.home-save.error",
                    defaultValue: "Travel Log couldn't save your home: \(error.localizedDescription). Please try again.",
                    comment: "Onboarding error when the selected home could not be saved."
                )
                showSaveError = true
                return
            }
        }
        isSaving = false
        onComplete()
    }
}

// MARK: - Step 4: Routine Places (Optional)

/// Lets the user add 0+ routine places before finishing onboarding.
/// Each place gets a label, map pin, and radius.
private struct RoutinePlacesStep: View {

    let onComplete: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var places: [RoutinePlaceEntry] = []
    @State private var showAddSheet = false
    @State private var saveErrorMessage = ""
    @State private var showSaveError = false

    var body: some View {
        OnboardingStepScaffold(icon: "building.2.fill") {
            Text(String(localized: "onboarding.routine.title", defaultValue: "Skip the everyday places.", comment: "Onboarding routine places headline."))
                .font(.title2.bold())
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
            Text(String(localized: "onboarding.routine.caption", defaultValue: "Work, gym, campus: places like these won't become trips.", comment: "Onboarding routine places caption."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } content: {
            VStack(spacing: 24) {
                if !places.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(places) { entry in
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text(entry.label)
                                    .font(.subheadline)
                                Spacer()
                                Button {
                                    places.removeAll { $0.id == entry.id }
                                } label: {
                                    Image(systemName: "xmark.circle")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 32)
                        }
                    }
                }

                Button {
                    showAddSheet = true
                } label: {
                    Label("Add a Place", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 32)
            }
        } actions: {
            Button(places.isEmpty ? "Skip for Now" : "Continue") {
                savePlacesAndFinish()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .sheet(isPresented: $showAddSheet) {
            AddRoutinePlaceOnboardingSheet { entry in
                places.append(entry)
            }
        }
        .alert("Couldn't Save Places", isPresented: $showSaveError) {
            Button("Try Again") { savePlacesAndFinish() }
            Button("Skip", role: .cancel) { onComplete() }
        } message: {
            Text(saveErrorMessage)
        }
    }

    private func savePlacesAndFinish() {
        var insertedPlaces: [RoutinePlace] = []
        for entry in places {
            let place = RoutinePlace(
                label: entry.label,
                latitude: entry.latitude,
                longitude: entry.longitude,
                radiusMeters: entry.radiusMeters
            )
            modelContext.insert(place)
            insertedPlaces.append(place)
        }
        do {
            try modelContext.save()
            onComplete()
        } catch {
            // RootView's onboardingComplete && !homes.isEmpty gate makes
            // silent save failures unsafe; routine places get an explicit Skip.
            for place in insertedPlaces {
                modelContext.delete(place)
            }
            saveErrorMessage = String(
                localized: "onboarding.routine-places-save.error",
                defaultValue: "Travel Log couldn't save your routine places: \(error.localizedDescription).",
                comment: "Onboarding error when routine places could not be saved."
            )
            showSaveError = true
        }
    }
}

// MARK: - Step 5: iCloud Sync

private struct ICloudSyncStep: View {

    let onComplete: () -> Void

    @AppStorage(AppDelegate.iCloudSyncEnabledKey) private var iCloudSyncEnabled = false
    @State private var initialEnabled: Bool?

    var body: some View {
        OnboardingStepScaffold(icon: "icloud.fill") {
            Text(String(localized: "onboarding.icloud.title", defaultValue: "Keep your trips on every device.", comment: "Onboarding iCloud step headline."))
                .font(.title2.bold())
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
            Text(String(localized: "onboarding.icloud.caption", defaultValue: "Synced privately through your iCloud.", comment: "Onboarding iCloud step caption."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } content: {
            Toggle("Sync with iCloud", isOn: $iCloudSyncEnabled)
                .padding(.horizontal, 32)
                .tint(.blue)
        } actions: {
            VStack(spacing: 12) {
                Button("Continue") {
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                // The container's CloudKit mode is fixed at launch from this
                // flag, so a mid-onboarding toggle can't start sync in this
                // process. Only promise a next-launch change when the toggle
                // actually differs from the value that configured this launch.
                if let initialEnabled {
                    Text(iCloudSyncEnabled != initialEnabled
                         ? "This takes effect the next time you open Travel Log."
                         : iCloudSyncEnabled
                            ? "iCloud sync is on."
                            : "You can turn this on later in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            if initialEnabled == nil {
                initialEnabled = iCloudSyncEnabled
            }
        }
    }
}

// MARK: - Step 8: Notifications

private struct NotificationStep: View {

    let onComplete: () -> Void

    @State private var authStatus: UNAuthorizationStatus?

    var body: some View {
        OnboardingStepScaffold(icon: "bell.badge.fill") {
            Text(String(localized: "onboarding.notifications.title", defaultValue: "Know when you land.", comment: "Onboarding notifications headline."))
                .font(.title2.bold())
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
            Text(String(localized: "onboarding.notifications.caption", defaultValue: "A hello when you arrive abroad, a welcome when you're back home. Optional.", comment: "Onboarding notifications caption."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } content: {
            if authStatus != nil {
                statusView
                    .padding(.horizontal)
                    .transition(.opacity)
            }
        } actions: {
            if authStatus != nil {
                actionButtons
                    .transition(.opacity)
            }
        }
        .onAppear { refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            refreshStatus()
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch authStatus {
        case .authorized, .provisional, .ephemeral:
            Label("Notifications enabled", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.subheadline)

        case .denied:
            Label("Notifications are off", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.subheadline.bold())

        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 12) {
            if authStatus == .authorized || authStatus == .provisional || authStatus == .ephemeral {
                Button("Continue") {
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else if authStatus == .denied {
                // Pre-existing denial (re-onboarding, or the user declined
                // the prompt): iOS will not show the dialog again, so an
                // "Enable" button would silently do nothing — the honest
                // path is Settings. The didBecomeActive refresh picks up a
                // grant made there.
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Continue") {
                    onComplete()
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else {
                Button("Continue") {
                    requestPermission()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private func requestPermission() {
        Task {
            let granted = await NotificationService.requestAuthorization()
            if granted {
                UserDefaults.standard.set(true, forKey: NotificationService.countryWelcomeEnabledKey)
                UserDefaults.standard.set(true, forKey: NotificationService.welcomeHomeEnabledKey)
                withAnimation(.easeInOut) {
                    authStatus = .authorized
                }
            } else {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                withAnimation(.easeInOut) {
                    authStatus = settings.authorizationStatus
                }
            }
        }
    }

    private func refreshStatus() {
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            withAnimation(.easeInOut) {
                authStatus = settings.authorizationStatus
            }
            if authStatus == .authorized || authStatus == .provisional || authStatus == .ephemeral {
                // Passive observation of a grant (fresh flow, or the user
                // granted via Settings.app while on this step) turns the
                // feature flags on only when they were never set — a key
                // that exists holds a deliberate Settings-toggle choice
                // that re-onboarding must not overwrite. The explicit
                // Enable button (requestPermission) still sets both
                // unconditionally: tapping it IS the choice.
                let defaults = UserDefaults.standard
                if defaults.object(forKey: NotificationService.countryWelcomeEnabledKey) == nil {
                    defaults.set(true, forKey: NotificationService.countryWelcomeEnabledKey)
                }
                if defaults.object(forKey: NotificationService.welcomeHomeEnabledKey) == nil {
                    defaults.set(true, forKey: NotificationService.welcomeHomeEnabledKey)
                }
            }
        }
    }
}

// MARK: - Step 6: Photo Library

private struct PhotoPermissionStep: View {

    /// Shared onboarding state — mirror `authStatus` here whenever it
    /// changes so the downstream `PhotoImportStep` knows whether to
    /// show itself or auto-skip without re-querying PhotoKit.
    @Bindable var state: OnboardingState

    let onComplete: () -> Void

    @State private var authStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    var body: some View {
        OnboardingStepScaffold(icon: "photo.on.rectangle.angled") {
            Text(String(localized: "onboarding.photos.title", defaultValue: "Bring your photos into your trips.", comment: "Onboarding photo permission headline."))
                .font(.title2.bold())
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
            Text(String(localized: "onboarding.photos.caption", defaultValue: "Matched on your device by time and place. Never uploaded or changed.", comment: "Onboarding photo permission caption."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } content: {
            statusView
                .padding(.horizontal)
        } actions: {
            actionButtons
        }
        .onAppear {
            PhotoService.shared.refreshAuthorizationStatus()
            authStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            state.photoAuthStatus = authStatus
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // Keep `PhotoService.shared.authorizationStatus` in sync — without
            // this, a user who grants access via Settings.app (rather than the
            // in-app prompt) returns to a `PhotoService` that still thinks auth
            // is `.notDetermined`, and `photosForTrip` short-circuits to `[]`
            // until the next scenePhase or library-change event.
            PhotoService.shared.refreshAuthorizationStatus()
            authStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            state.photoAuthStatus = authStatus
        }
        .onChange(of: authStatus) { _, newStatus in
            // Mirror every auth transition into shared onboarding state
            // so PhotoImportStep doesn't need to re-query PhotoKit on
            // its own appear.
            state.photoAuthStatus = newStatus
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch authStatus {
        case .authorized:
            Label("Photo access granted", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.subheadline)

        case .limited:
            Label("Selected photos will be matched", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.subheadline)
                .multilineTextAlignment(.center)

        case .denied:
            VStack(spacing: 8) {
                Label("Photo access denied", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.subheadline.bold())
                Text("You can allow access later in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .restricted:
            VStack(spacing: 8) {
                Label("Photo access restricted", systemImage: "lock.fill")
                    .foregroundStyle(.red)
                    .font(.subheadline.bold())
                Text("This device doesn't allow photo access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 12) {
            if authStatus == .authorized || authStatus == .limited {
                Button("Continue") {
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else if authStatus == .denied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Continue") {
                    onComplete()
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else if authStatus == .restricted {
                Button("Continue") {
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button("Continue") {
                    requestPermission()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private func requestPermission() {
        Task {
            let status = await PhotoService.shared.requestAuthorization()
            authStatus = status
        }
    }
}

// MARK: - Shared Onboarding State

/// Cross-step state shared by `OnboardingView`'s children. Currently
/// holds only `photoAuthStatus`, mirrored by `PhotoPermissionStep` so
/// that `PhotoImportStep` can decide whether to render or auto-skip
/// without re-querying `PHPhotoLibrary.authorizationStatus(for:)`
/// (which would also re-trigger the eager-init-deferred path we
/// guard in `AppDelegate` — see the gated `_ = PhotoService.shared`).
///
/// `@Observable` so steps see updates in real time as the user
/// interacts with the system permission alert.
@Observable
final class OnboardingState {
    var photoAuthStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
}

// MARK: - Step 7: Photo Library Import

/// Offers the user the option to scan their photo library and
/// reconstruct trips taken before installing TravelLog.
///
/// **Auto-skip rules**:
///   - `.denied` / `.restricted` / `.notDetermined` → skip silently
///     (the user already declined or wasn't asked). `onComplete()`
///     fires on appear.
///   - `.limited` → show a softened title ("Reconstruct past trips
///     from your selected photos?"). The import still works on the
///     limited subset.
///   - `.authorized` → show the standard title.
///
/// **Actions:**
///   - **Scan Now** → submits a `BGContinuedProcessingTaskRequest`
///     via `PhotoImportService.start(...)`. Returns immediately and
///     advances to the next onboarding step; the import continues
///     in the background while the user finishes onboarding and
///     starts exploring the app. The system progress UI (Dynamic
///     Island / Lock Screen) shows progress.
///   - **Skip for Now** → advances without starting. The user can
///     trigger from Settings → Photo Library Import later.
///
/// **Error handling:** if `start()` throws (BG task submission
/// failure, permission edge case), an alert appears with options to
/// retry or skip. We don't block onboarding behind a successful
/// start — the user can always try later from Settings.
private struct PhotoImportStep: View {

    @Bindable var state: OnboardingState
    let onComplete: () -> Void

    @State private var isStarting = false
    @State private var errorMessage: String?
    @State private var showError = false

    /// Prevents `onComplete()` from firing more than once across
    /// re-renders of the skip path. SwiftUI's `.onAppear` can fire
    /// multiple times if the parent body re-evaluates (e.g. on a
    /// scene-phase change) — without this guard, an auth transition
    /// could fire `onComplete()` twice and skip past the next step.
    @State private var hasAdvanced = false

    var body: some View {
        Group {
            if shouldShowStep {
                stepBody
            } else {
                // Auth was .denied / .restricted / .notDetermined on
                // the previous step. Skip silently — the user's
                // intent is clear from the previous step.
                Color.clear
                    .onAppear { advance() }
            }
        }
        .alert("Couldn't Start Scan", isPresented: $showError, presenting: errorMessage) { _ in
            Button("Try Again") { Task { await runImport() } }
            Button("Not Now", role: .cancel) { advance() }
        } message: { message in
            Text(message)
        }
    }

    private var shouldShowStep: Bool {
        state.photoAuthStatus == .authorized || state.photoAuthStatus == .limited
    }

    @ViewBuilder
    private var stepBody: some View {
        OnboardingStepScaffold(icon: "wand.and.stars") {
            Text(titleText)
                .font(.title2.bold())
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
            Text(String(localized: "onboarding.photo-scan.caption", defaultValue: "Runs on your device. You can also start it later from Settings.", comment: "Onboarding photo scan caption."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } content: {
            EmptyView()
        } actions: {
            actionButtons
        }
    }

    private var titleText: String {
        switch state.photoAuthStatus {
        case .limited:
            return String(
                localized: "onboarding.photo-scan.title.limited",
                defaultValue: "Rebuild past trips from your selected photos.",
                comment: "Onboarding photo-scan title when access is limited to selected photos."
            )
        default:
            return String(
                localized: "onboarding.photo-scan.title.full",
                defaultValue: "Rebuild past trips from your photos.",
                comment: "Onboarding photo-scan title when full photo access is available."
            )
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button {
                Task { await runImport() }
            } label: {
                if isStarting {
                    ProgressView()
                        .controlSize(.regular)
                } else {
                    Text("Scan Now")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isStarting)

            Button("Not Now") {
                advance()
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .disabled(isStarting)

        }
    }

    private func advance() {
        guard !hasAdvanced else { return }
        hasAdvanced = true
        onComplete()
    }

    private func runImport() async {
        isStarting = true
        defer { isStarting = false }
        let deviceID = UIDevice.current.identifierForVendor?.uuidString ?? ""
        do {
            try await AppDelegate.photoImportService.start(originDeviceID: deviceID)
            // Don't wait for the import to finish — the BG task drives
            // it in the background. Advance to the next step so the
            // user can finish onboarding while the system progress UI
            // (Dynamic Island / Lock Screen) shows status.
            advance()
        } catch let error as PhotoImportError {
            errorMessage = userFacingMessage(for: error)
            showError = true
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func userFacingMessage(for error: PhotoImportError) -> String {
        switch error {
        case .alreadyRunning:
            return String(localized: "onboarding.photo-scan.error.already-running", defaultValue: "A photo scan is already running. Check its progress in Settings.", comment: "Onboarding photo-scan error when another scan is already running.")
        case .noPhotoPermission:
            return String(localized: "onboarding.photo-scan.error.no-permission", defaultValue: "Allow photo access in Settings → Privacy → Photos → Travel Log, then try again.", comment: "Onboarding photo-scan error when photo permission is missing.")
        case .noResumableState:
            return String(localized: "onboarding.photo-scan.error.no-resumable-state", defaultValue: "The scan couldn't resume. Please try again.", comment: "Onboarding photo-scan error when no resumable scan exists.")
        case .persistenceFailure(let detail):
            return String(localized: "onboarding.photo-scan.error.persistence", defaultValue: "The scan couldn't be saved: \(detail)", comment: "Onboarding photo-scan error when its state could not be saved.")
        case .incompleteLocalData:
            return String(localized: "onboarding.photo-scan.error.incomplete-local-data", defaultValue: "Location records are still syncing from iCloud. Try again when sync finishes.", comment: "Onboarding photo-scan error when required iCloud data is still syncing.")
        case .inconsistentLocalData:
            return String(localized: "onboarding.photo-scan.error.inconsistent-local-data", defaultValue: "The scan couldn't safely rebuild your trips. Reopen Travel Log and try again.", comment: "Onboarding photo-scan error when local imported data is inconsistent.")
        case .bgTaskSubmissionFailed(let detail):
            return String(localized: "onboarding.photo-scan.error.background-task", defaultValue: "The background scan couldn't start: \(detail)", comment: "Onboarding photo-scan error when the background task could not start.")
        case .lowPowerMode:
            return String(localized: "onboarding.photo-scan.error.low-power-mode", defaultValue: "Turn off Low Power Mode and try again, or scan later from Settings.", comment: "Onboarding photo-scan error when Low Power Mode prevents scanning.")
        case .insufficientDiskSpace(let bytesAvailable):
            let mb = bytesAvailable / (1024 * 1024)
            return String(localized: "onboarding.photo-scan.error.insufficient-storage", defaultValue: "Not enough storage (\(mb, format: .number.grouping(.never)) MB available). Free up space, then try again.", comment: "Onboarding photo-scan error showing available storage in megabytes.")
        }
    }
}

/// A lightweight value type to hold a routine place before persisting it.
private struct RoutinePlaceEntry: Identifiable {
    let id = UUID()
    let label: String
    let latitude: Double
    let longitude: Double
    let radiusMeters: Double
}

/// Sheet for adding a single routine place during onboarding.
private struct AddRoutinePlaceOnboardingSheet: View {

    let onSave: (RoutinePlaceEntry) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var selectedCoordinate: CLLocationCoordinate2D?
    @State private var radiusMeters: Double = 500.0
    @State private var showMapPicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("University, gym, or office", text: $label)
                }

                Section("Location") {
                    if let coord = selectedCoordinate {
                        Label("Location set", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)

                        RadiusMapPreview(coordinate: coord, radiusMeters: radiusMeters)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    }

                    Button {
                        showMapPicker = true
                    } label: {
                        Label(
                            selectedCoordinate == nil ? "Choose on Map" : "Change Location",
                            systemImage: "map"
                        )
                    }
                }

                Section("Radius") {
                    VStack {
                        Slider(value: $radiusMeters, in: 100...2000, step: 100)
                        Text(UnitsFormatter.formatRoutineRadius(radiusMeters))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Add Routine Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let coord = selectedCoordinate else { return }
                        onSave(RoutinePlaceEntry(
                            label: label,
                            latitude: coord.latitude,
                            longitude: coord.longitude,
                            radiusMeters: radiusMeters
                        ))
                        dismiss()
                    }
                    .disabled(label.isEmpty || selectedCoordinate == nil)
                }
            }
            .navigationDestination(isPresented: $showMapPicker) {
                MapLocationPicker(selectedCoordinate: $selectedCoordinate)
                    .navigationTitle("Choose Location")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showMapPicker = false }
                        }
                    }
            }
        }
    }
}
