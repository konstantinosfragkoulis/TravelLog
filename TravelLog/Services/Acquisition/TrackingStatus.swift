//
//  TrackingStatus.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import Foundation
import CoreLocation
import UIKit
import os.log

/// Monitors and reports the health of background location tracking.
///
/// This observable object checks all the prerequisites for reliable SLC monitoring
/// and exposes them to the UI so the user can diagnose issues.
///
/// ## Swift 6 Concurrency Notes
///
/// `CLLocationManager.locationServicesEnabled()` blocks the calling thread,
/// so we call it via a `nonisolated static` helper that uses `Task.detached`.
/// Notification observation uses async `notifications(named:)` sequences
/// instead of closure-based `addObserver`, avoiding `@Sendable` capture issues.
@MainActor
@Observable
final class TrackingStatus {

    // MARK: - State

    /// Whether all prerequisites are met for reliable background tracking.
    var isFullyOperational: Bool {
        isSignificantChangeMonitoringAvailable
            && hasAlwaysPermission
            && hasFullAccuracy
            && isBackgroundRefreshEnabled
            && locationServicesEnabled
    }

    /// Whether the device can monitor significant location changes at all.
    /// Without it `LocationService.startMonitoring` starts neither SLC nor
    /// Visits, whatever the permissions. A hardware capability, read once.
    let isSignificantChangeMonitoringAvailable: Bool

    var hasAlwaysPermission: Bool {
        currentAuthorizationStatus == .authorizedAlways
    }

    var hasAnyPermission: Bool {
        let status = currentAuthorizationStatus
        return status == .authorizedAlways || status == .authorizedWhenInUse
    }

    var hasFullAccuracy: Bool {
        currentAccuracyAuthorization == .fullAccuracy
    }

    var isBackgroundRefreshEnabled: Bool {
        currentBackgroundRefreshStatus == .available
    }

    /// Cached value, updated off the main thread.
    private(set) var locationServicesEnabled: Bool = true
    private(set) var currentAuthorizationStatus: CLAuthorizationStatus
    /// Stored snapshots so a change the user makes in Settings re-renders the
    /// dashboard; the sources themselves are not observable.
    private(set) var currentAccuracyAuthorization: CLAccuracyAuthorization
    private(set) var currentBackgroundRefreshStatus: UIBackgroundRefreshStatus

    var isMonitoring: Bool {
        LocationService.shared.isMonitoring
    }

    // MARK: - Diagnostics

    /// Human-readable list of issues preventing full operation.
    var issues: [TrackingIssue] {
        var result: [TrackingIssue] = []

        if !isSignificantChangeMonitoringAvailable {
            result.append(.monitoringUnavailable)
        }

        if !locationServicesEnabled {
            result.append(.locationServicesDisabled)
        }

        switch currentAuthorizationStatus {
        case .notDetermined:
            result.append(.permissionNotDetermined)
        case .restricted:
            result.append(.permissionRestricted)
        case .denied:
            result.append(.noPermission)
        case .authorizedWhenInUse:
            result.append(.whenInUseOnly)
        case .authorizedAlways:
            break
        @unknown default:
            break
        }

        if hasAnyPermission && !hasFullAccuracy {
            result.append(.reducedAccuracy)
        }

        if !isBackgroundRefreshEnabled {
            result.append(.backgroundRefreshDisabled)
        }

        return result
    }

    // MARK: - Initialization

    private let logger = Logger(subsystem: "com.travellog.app", category: "TrackingStatus")
    private let authorizationStatus: () -> CLAuthorizationStatus
    private let accuracyAuthorization: () -> CLAccuracyAuthorization
    private let backgroundRefreshStatus: () -> UIBackgroundRefreshStatus

    /// The initial check plus both notification-observer loops, OWNED so they
    /// can be cancelled deterministically. `[weak self]` alone is not enough:
    /// a dormant `for await` loop keeps its NotificationCenter subscription
    /// alive until the NEXT notification arrives and the `guard let self`
    /// finally fails — so every StatusDashboardView visit would stack up to
    /// two more suspended observers.
    /// The tasks capture self weakly, so owning the handles creates no cycle.
    @ObservationIgnored private var observerTasks: [Task<Void, Never>] = []

    init(
        authorizationStatus: @escaping () -> CLAuthorizationStatus = {
            LocationService.shared.authorizationStatus
        },
        accuracyAuthorization: @escaping () -> CLAccuracyAuthorization = {
            LocationService.shared.accuracyAuthorization
        },
        backgroundRefreshStatus: @escaping () -> UIBackgroundRefreshStatus = {
            UIApplication.shared.backgroundRefreshStatus
        },
        significantChangeMonitoringAvailable: () -> Bool = {
            CLLocationManager.significantLocationChangeMonitoringAvailable()
        }
    ) {
        self.isSignificantChangeMonitoringAvailable = significantChangeMonitoringAvailable()
        self.authorizationStatus = authorizationStatus
        self.accuracyAuthorization = accuracyAuthorization
        self.backgroundRefreshStatus = backgroundRefreshStatus
        self.currentAuthorizationStatus = authorizationStatus()
        self.currentAccuracyAuthorization = accuracyAuthorization()
        self.currentBackgroundRefreshStatus = backgroundRefreshStatus()
        // Initial check off main thread.
        observerTasks.append(Task { [weak self] in
            let enabled = await Self.checkLocationServicesOffMain()
            self?.locationServicesEnabled = enabled
        })

        // Re-check when authorization changes (user may have toggled global Location Services).
        observerTasks.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .locationAuthorizationChanged) {
                guard let self else { return }
                let enabled = await Self.checkLocationServicesOffMain()
                self.locationServicesEnabled = enabled
                self.refreshSnapshot()
                self.logger.debug("Authorization changed. Location services enabled: \(enabled)")
            }
        })

        // Re-check when app becomes active (user may have returned from Settings).
        observerTasks.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
                guard let self else { return }
                let enabled = await Self.checkLocationServicesOffMain()
                self.locationServicesEnabled = enabled
                self.refreshSnapshot()
            }
        })
    }

    /// Re-reads the unobservable sources into the observed stored values.
    private func refreshSnapshot() {
        currentAuthorizationStatus = authorizationStatus()
        currentAccuracyAuthorization = accuracyAuthorization()
        currentBackgroundRefreshStatus = backgroundRefreshStatus()
    }

    deinit {
        // Ends both async-sequence loops now, not at the next notification.
        for task in observerTasks { task.cancel() }
    }

    #if DEBUG
    /// Test seam: the owned handles, so a lifecycle test can assert they are
    /// cancelled once the instance is released.
    var observerTasksForTesting: [Task<Void, Never>] { observerTasks }
    #endif

    /// Check `CLLocationManager.locationServicesEnabled()` off the main thread.
    ///
    /// This is a synchronous class method that Apple warns can cause UI
    /// unresponsiveness on the main thread. We run it in a detached task
    /// and await the result.
    nonisolated private static func checkLocationServicesOffMain() async -> Bool {
        await Task.detached {
            CLLocationManager.locationServicesEnabled()
        }.value
    }
}

// MARK: - TrackingIssue

/// A specific issue preventing full background tracking.
enum TrackingIssue: Identifiable {
    case monitoringUnavailable
    case locationServicesDisabled
    case permissionNotDetermined
    case permissionRestricted
    case noPermission
    case whenInUseOnly
    case reducedAccuracy
    case backgroundRefreshDisabled

    var id: String { title }

    var title: String {
        switch self {
        case .monitoringUnavailable:
            String(localized: "tracking.issue.monitoring-unavailable.title", defaultValue: "Background Tracking Unavailable", comment: "Tracking issue title when the device cannot monitor significant location changes.")
        case .locationServicesDisabled:
            String(localized: "tracking.issue.location-services-disabled.title", defaultValue: "Location Services Disabled", comment: "Tracking issue title.")
        case .permissionNotDetermined:
            String(localized: "root.tracking-warning.title.not-recording", defaultValue: "Trips aren't being recorded", comment: "Tracking warning headline when location access does not allow trip recording.")
        case .permissionRestricted:
            String(localized: "Location access restricted")
        case .noPermission:
            String(localized: "tracking.issue.permission-denied.title", defaultValue: "Location Permission Denied", comment: "Tracking issue title.")
        case .whenInUseOnly:
            String(localized: "tracking.issue.always-permission.title", defaultValue: "\"Always\" Permission Required", comment: "Tracking issue title.")
        case .reducedAccuracy:
            String(localized: "tracking.issue.reduced-accuracy.title", defaultValue: "Precise Location is off. Trips may be less accurate", comment: "Tracking issue title when Precise Location is disabled.")
        case .backgroundRefreshDisabled:
            String(localized: "tracking.issue.background-refresh-disabled.title", defaultValue: "Background App Refresh Disabled", comment: "Tracking issue title.")
        }
    }

    var description: String {
        switch self {
        case .monitoringUnavailable:
            String(localized: "tracking.issue.monitoring-unavailable.description", defaultValue: "This device can't watch for significant location changes, so Travel Log can't record your trips in the background.", comment: "Explanation when the device cannot monitor significant location changes, so trips are not recorded in the background.")
        case .locationServicesDisabled:
            String(localized: "tracking.issue.location-services-disabled.description", defaultValue: "Location Services are turned off for the entire device. Go to Settings → Privacy & Security → Location Services and turn them on.", comment: "Instructions for fixing disabled Location Services.")
        case .permissionNotDetermined:
            String(localized: "root.tracking-warning.detail.not-determined", defaultValue: "Location access hasn't been set up, so Travel Log can't record your trips.", comment: "Tracking warning detail before the user has chosen a location permission.")
        case .permissionRestricted:
            String(localized: "This device doesn't allow Travel Log to request location access, possibly due to parental controls or a management profile.")
        case .noPermission:
            String(localized: "tracking.issue.permission-denied.description", defaultValue: "Travel Log does not have permission to access your location. Go to Settings → Travel Log → Location and select \"Always\".", comment: "Instructions for granting location permission to Travel Log.")
        case .whenInUseOnly:
            String(localized: "tracking.issue.always-permission.description", defaultValue: "Travel Log can only track your location while the app is open. For background tracking (including after restarts), go to Settings → Travel Log → Location and select \"Always\".", comment: "Instructions for granting Always location permission to Travel Log.")
        case .reducedAccuracy:
            String(localized: "tracking.issue.reduced-accuracy.description", defaultValue: "Go to Settings → Travel Log → Location and turn on Precise Location.", comment: "Instructions for enabling Precise Location for Travel Log.")
        case .backgroundRefreshDisabled:
            String(localized: "tracking.issue.background-refresh-disabled.description", defaultValue: "Background App Refresh is disabled. Without this, Travel Log cannot be relaunched after iOS terminates it. Go to Settings → General → Background App Refresh and enable it for Travel Log.", comment: "Instructions for enabling Background App Refresh for Travel Log.")
        }
    }

    /// Whether this issue can be resolved by opening Settings.
    var canOpenSettings: Bool {
        switch self {
        case .monitoringUnavailable, .permissionNotDetermined, .permissionRestricted: false
        default: true
        }
    }

    var canRequestPermission: Bool { self == .permissionNotDetermined }
}
