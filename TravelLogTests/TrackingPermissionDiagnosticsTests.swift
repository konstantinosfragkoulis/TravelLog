import CoreLocation
import Synchronization
import Testing
import UIKit
@testable import TravelLog

@MainActor
struct TrackingPermissionDiagnosticsTests {
    @Test("Undecided, restricted and denied location access have distinct recovery actions")
    func permissionIssues() {
        let cases: [(CLAuthorizationStatus, TrackingIssue, Bool, Bool)] = [
            (.notDetermined, .permissionNotDetermined, false, true),
            (.restricted, .permissionRestricted, false, false),
            (.denied, .noPermission, true, false),
            (.authorizedWhenInUse, .whenInUseOnly, true, false)
        ]
        for (authorization, expected, opensSettings, requestsPermission) in cases {
            let status = TrackingStatus(authorizationStatus: { authorization })
            let permissionIssues = status.issues.filter {
                switch $0 {
                case .permissionNotDetermined, .permissionRestricted, .noPermission, .whenInUseOnly: true
                default: false
                }
            }
            #expect(permissionIssues == [expected])
            #expect(expected.canOpenSettings == opensSettings)
            #expect(expected.canRequestPermission == requestsPermission)
            #expect(!expected.title.isEmpty)
            #expect(!expected.description.isEmpty)
        }
    }

    @Test("Diagnostics refresh location authorization after a notification", arguments: [
        Notification.Name.locationAuthorizationChanged,
        UIApplication.didBecomeActiveNotification
    ])
    func permissionChanges(notification: Notification.Name) async throws {
        var authorization: CLAuthorizationStatus = .notDetermined
        let status = TrackingStatus(authorizationStatus: { authorization })
        #expect(status.issues.contains(.permissionNotDetermined))
        #expect(!status.hasAnyPermission)

        authorization = .authorizedAlways
        #expect(!status.hasAnyPermission)
        for _ in 0..<400 {
            NotificationCenter.default.post(name: notification, object: nil)
            try await Task.sleep(for: .milliseconds(5))
            if status.hasAlwaysPermission { break }
        }
        #expect(status.hasAnyPermission)
        #expect(status.hasAlwaysPermission)
        #expect(!status.issues.contains(.permissionNotDetermined))
        #expect(!status.issues.contains(.noPermission))
        #expect(!status.issues.contains(.whenInUseOnly))
    }

    @Test("Diagnostics refresh Precise Location and Background App Refresh after a notification", arguments: [
        Notification.Name.locationAuthorizationChanged,
        UIApplication.didBecomeActiveNotification
    ])
    func accuracyAndRefreshChanges(notification: Notification.Name) async throws {
        var accuracy: CLAccuracyAuthorization = .reducedAccuracy
        var refresh: UIBackgroundRefreshStatus = .denied
        let status = TrackingStatus(
            authorizationStatus: { .authorizedAlways },
            accuracyAuthorization: { accuracy },
            backgroundRefreshStatus: { refresh }
        )
        #expect(status.issues.contains(.reducedAccuracy))
        #expect(status.issues.contains(.backgroundRefreshDisabled))

        let fired = Mutex(false)
        withObservationTracking({ _ = status.issues }, onChange: { fired.withLock { $0 = true } })
        accuracy = .fullAccuracy
        refresh = .available
        for _ in 0..<400 {
            NotificationCenter.default.post(name: notification, object: nil)
            try await Task.sleep(for: .milliseconds(5))
            if fired.withLock({ $0 }) && status.isBackgroundRefreshEnabled { break }
        }
        #expect(fired.withLock { $0 })
        #expect(status.hasFullAccuracy)
        #expect(!status.issues.contains(.reducedAccuracy))
        #expect(!status.issues.contains(.backgroundRefreshDisabled))
    }
}
