import CloudKit
import Testing
@testable import TravelLog

/// A fresh photo scan on an iCloud device waits for another device's
/// history to arrive, so the scan cannot rebuild its trips a second time.
struct CloudScanGateTests {
    @Test("Without iCloud, or after this device's first import, a scan never waits or asks CloudKit")
    func noRemoteCheckNeeded() {
        #expect(!CloudScanGate.mayNeedRemoteCheck(iCloudSyncEnabled: false, importedBefore: false))
        #expect(!CloudScanGate.mayNeedRemoteCheck(iCloudSyncEnabled: true, importedBefore: true))
        for remote in [CloudScanGate.RemoteHistory.none, .present, .unknown] {
            #expect(!CloudScanGate.holds(iCloudSyncEnabled: false, importedBefore: false, remote: remote))
            #expect(!CloudScanGate.holds(iCloudSyncEnabled: true, importedBefore: true, remote: remote))
        }
    }

    @Test("Before the first import, only an account holding none of the app's data lets the scan run")
    func firstDeviceOnly() {
        #expect(CloudScanGate.mayNeedRemoteCheck(iCloudSyncEnabled: true, importedBefore: false))
        #expect(!CloudScanGate.holds(iCloudSyncEnabled: true, importedBefore: false, remote: .none))
        #expect(CloudScanGate.holds(iCloudSyncEnabled: true, importedBefore: false, remote: .present))
        #expect(CloudScanGate.holds(iCloudSyncEnabled: true, importedBefore: false, remote: .unknown))
    }

    @Test("The probe reads the zone the store is mirrored into")
    func mirrorZone() {
        #expect(CloudScanGate.mirrorZone.zoneName == "com.apple.coredata.cloudkit.zone")
    }
}
