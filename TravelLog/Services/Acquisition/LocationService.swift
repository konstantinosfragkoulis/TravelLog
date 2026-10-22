//
//  LocationService.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//


import Foundation
import CoreLocation
import os.log

/// Manages Significant Location Change and system visit monitoring with Always
/// authorization. AppDelegate connects location and visit callbacks to their
/// recorders; iOS controls background delivery and relaunch timing.
///
/// ForegroundLocationStreamController owns the foreground-only live stream and
/// uses this service for validation, delivery and one-shot fallback requests.
/// Foreground fallback must not request additional permission.
final class LocationService: NSObject, Sendable {

    static let shared = LocationService()

    private let logger = Logger(subsystem: "com.travellog.app", category: "LocationService")

    // MARK: - Location Manager

    /// The location manager must be created on the main thread and its delegate
    /// set immediately. We use `nonisolated(unsafe)` because CLLocationManager
    /// is not Sendable but we guarantee single-threaded access via MainActor.
    nonisolated(unsafe) private let locationManager: CLLocationManager

    // MARK: - State

    /// Called on the main actor when a new location is received.
    /// Connected by `AppDelegate` to `PingRecorder` during app initialization.
    @MainActor
    var onLocationUpdate: (([LiveLocationCandidate]) async -> Void)?

    /// Called on the main actor when Core Location delivers a visit observation.
    @MainActor
    var onVisitObservation: ((VisitObservation) async -> Void)?

    /// Whether production SLC and visit monitoring have been requested.
    @MainActor
    private(set) var isMonitoring = false

    /// Whether iOS is currently providing full or reduced location accuracy.
    /// Refreshed alongside authorization changes so diagnostics can surface a
    /// disabled Precise Location toggle without changing ping acceptance.
    @MainActor
    private(set) var accuracyAuthorization: CLAccuracyAuthorization

    /// Armed only by an explicit in-app When-In-Use request.
    @MainActor
    private var pendingAlwaysEscalation = false

    // MARK: - Init

    private override init() {
        let manager = CLLocationManager()
        self.locationManager = manager
        self.accuracyAuthorization = manager.accuracyAuthorization
        super.init()
        locationManager.delegate = self
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    // MARK: - Public API

    /// Start monitoring for significant location changes and system visits.
    ///
    /// Safe to call multiple times - if already monitoring, this is a no-op.
    /// Must be called from the main actor (CLLocationManager requirement).
    @MainActor
    func startMonitoring() {
        guard CLLocationManager.significantLocationChangeMonitoringAvailable() else {
            logger.error("Significant location change monitoring is not available on this device.")
            isMonitoring = false
            return
        }

        // SLC requires `.authorizedAlways` per Apple's API contract. With only
        // `.authorizedWhenInUse`, the call registers but background delivery is
        // silently dropped — and the user is left believing tracking is active
        // when no pings will arrive. Refuse to set `isMonitoring = true` in
        // that state so `TrackingStatus` and the diagnostic dashboard surface
        // an accurate picture. Onboarding warns and allows continuing without
        // tracking, so this guard covers that path as well as a runtime
        // permission downgrade in Settings.app.
        guard locationManager.authorizationStatus == .authorizedAlways else {
            logger.error("SLC requires .authorizedAlways; current status raw value: \(self.locationManager.authorizationStatus.rawValue). Not starting.")
            isMonitoring = false
            return
        }
        guard !isMonitoring else { return }

        locationManager.startMonitoringSignificantLocationChanges()

        if UserDefaults.standard.object(
            forKey: VisitRecorder.acceptanceFloorKey
        ) == nil {
            UserDefaults.standard.set(
                Date.now,
                forKey: VisitRecorder.acceptanceFloorKey
            )
        }
        locationManager.startMonitoringVisits()

        isMonitoring = true
        logger.info("Started monitoring significant location changes.")
    }

    /// Request location authorization using the two-step iOS flow.
    ///
    /// On iOS 14+, you cannot jump directly to "Always". The correct flow is:
    /// 1. Request "When In Use" first (shows the initial system dialog)
    /// 2. Once granted, request "Always" (shows the upgrade prompt)
    ///
    /// This explicit request arms the delegate's one-shot escalation from
    /// WhenInUse → Always. Automatic launch-time status reports do not arm it.
    @MainActor
    func requestWhenInUseAuthorization() {
        pendingAlwaysEscalation = true
        locationManager.requestWhenInUseAuthorization()
    }

    /// Request upgrade from "When In Use" to "Always" authorization.
    ///
    /// Only call this AFTER the user has already granted "When In Use".
    /// iOS will show a second prompt offering the "Always" option.
    @MainActor
    func requestAlwaysAuthorization() {
        locationManager.requestAlwaysAuthorization()
    }

    /// The current authorization status.
    @MainActor
    var authorizationStatus: CLAuthorizationStatus {
        locationManager.authorizationStatus
    }

    /// Whether we have at least "When In Use" (degraded but functional when foregrounded).
    @MainActor
    var hasAnyPermission: Bool {
        let status = locationManager.authorizationStatus
        return status == .authorizedAlways || status == .authorizedWhenInUse
    }

    @MainActor
    func deliverLocationCandidates(
        _ candidates: [LiveLocationCandidate]
    ) async {
        await onLocationUpdate?(candidates)
    }

    @MainActor
    func isValidLiveLocation(
        _ location: CLLocation,
        now: Date = .now
    ) -> Bool {
        // Reject readings older than 5 minutes.
        let age = abs(location.timestamp.timeIntervalSince(now))
        guard age < 300 else {
            logger.debug("Discarding stale location (age: \(Int(age))s)")
            return false
        }
        // Reject wildly inaccurate readings (at least 5 km uncertainty).
        guard location.horizontalAccuracy >= 0,
              location.horizontalAccuracy < 5000 else {
            logger.debug("Discarding inaccurate location (accuracy: \(location.horizontalAccuracy)m)")
            return false
        }
        // Reject fixes that report a valid, high GPS altitude — e.g. a rare
        // in-flight GPS lock — which would otherwise be clustered, classified
        // as transit, painted on the hex map, and counted toward "visited"
        // surfaces. 5 km threshold mirrors `PhotoImportService.shouldAccept`
        // so the live and import paths agree. The `verticalAccuracy` bracket
        // [0, 200] is REQUIRED, not incidental: a negative verticalAccuracy
        // means the altitude reading is garbage, and rejecting on a garbage
        // altitude would drop legitimate ground fixes.
        //
        // LIMITATION: the common in-cabin case is a cell-tower /
        // Wi-Fi fix, which carries NO valid altitude (verticalAccuracy < 0),
        // so this filter cannot catch it — altitude-based rejection is
        // physically impossible without a GPS altitude. Those phantom
        // in-flight fixes are instead mitigated downstream: the aerial
        // hex-hide rule (`HexVisibility`, flight/airport) and TransitInferer's
        // geometry-only `.flight` detection (≥300 km + airport endpoint +
        // impossible ground speed) keep most of them off "visited" surfaces.
        // Best-effort by design; not a guarantee.
        if location.altitude > 5000,
           location.verticalAccuracy >= 0,
           location.verticalAccuracy <= 200 {
            logger.debug("Discarding airborne fix (altitude: \(Int(location.altitude))m, vAcc: \(Int(location.verticalAccuracy))m)")
            return false
        }
        return true
    }

    /// Request a one-shot location for onboarding's first ping, the activation fix, and background refresh.
    @MainActor
    func requestCurrentLocation() {
        guard hasAnyPermission else { return }
        locationManager.requestLocation()
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationService: CLLocationManagerDelegate {

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard !locations.isEmpty else { return }

        logger.info("Received \(locations.count) location update(s).")

        // The delegate and foreground stream share the exact live-fix filter.
        let validLocations = locations.filter { isValidLiveLocation($0) }

        guard !validLocations.isEmpty else { return }

        Task { @MainActor in
            let candidates = validLocations.map {
                LiveLocationCandidate($0, source: .liveSLC)
            }
            await deliverLocationCandidates(candidates)
        }
    }

    func locationManager(
        _ manager: CLLocationManager,
        didVisit visit: CLVisit
    ) {
        let observation = VisitObservation(source: visit, receivedAt: .now)
        Task { @MainActor in
            await onVisitObservation?(observation)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let clError = error as? CLError
        logger.error("Location manager error: \(error.localizedDescription) (code: \(clError?.code.rawValue ?? -1))")

        // CLError.denied - user revoked permission. We can't recover automatically.
        // CLError.network - temporary. SLC will retry on next cell tower change.
        // CLError.locationUnknown - temporary. Same.
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization
        logger.info("Authorization status changed: \(String(describing: status.rawValue))")

        // Auto-escalate only after the user explicitly started the in-app
        // request flow, not from an automatic status report at app launch.
        if status == .authorizedWhenInUse && pendingAlwaysEscalation {
            pendingAlwaysEscalation = false
            logger.info("Got WhenInUse - requesting Always authorization upgrade.")
            manager.requestAlwaysAuthorization()
        }
        if status != .notDetermined {
            pendingAlwaysEscalation = false
        }

        if status == .authorizedAlways {
            startMonitoring()
        } else {
            manager.stopMonitoringSignificantLocationChanges()
            manager.stopMonitoringVisits()
            isMonitoring = false
        }

        // Post a notification so the UI can react to permission changes
        NotificationCenter.default.post(
            name: .locationAuthorizationChanged,
            object: nil,
            userInfo: ["status": status.rawValue]
        )
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted when location authorization status changes.
    nonisolated static let locationAuthorizationChanged = Notification.Name("locationAuthorizationChanged")
}
