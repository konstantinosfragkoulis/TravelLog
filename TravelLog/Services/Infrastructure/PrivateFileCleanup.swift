//
//  PrivateFileCleanup.swift
//  TravelLog
//
//  Checked removal of the personal files Delete All Data owes outside the
//  store: staged backups and shares, received copies in the Inbox, the
//  shared-trip ledger and the Debug build's diagnostics recorders. A file
//  that is already gone is cleared; a folder that
//  cannot be listed or a file that cannot be removed is not, so the wipe
//  reports it instead of claiming success.
//

import Foundation
import os.log

nonisolated enum PrivateFileCleanup {

    private static let logger = Logger(
        subsystem: "com.travellog.app", category: "PrivateFileCleanup")

    /// Where the files live; tests point every one at a scratch folder.
    nonisolated struct Locations: Sendable {
        /// Staged exports, restore copies and staged shares.
        var temporary: URL
        /// Copies the system handed over without opening them in place.
        var inbox: URL?
        /// The shared-trip ledger's and the diagnostics recorders' folder;
        /// nil is the app's own.
        var applicationSupport: URL?

        static var application: Locations {
            Locations(
                temporary: FileManager.default.temporaryDirectory,
                inbox: OpenedFile.inboxDirectory,
                applicationSupport: nil)
        }
    }

    /// Removes every one of them, each attempted even after another failed.
    /// False while any could remain.
    static func removeDeleteAllDataFiles(at locations: Locations = .application) -> Bool {
        var cleared = TripDataExporter.removeStagedExportsChecked(in: locations.temporary)
        cleared = OpenedFile.removeInboxCopies(in: locations.inbox) && cleared
        do {
            try SharedTripLedger.clear(in: locations.applicationSupport)
        } catch {
            logger.error("The shared-trip ledger could not be cleared: \(error.localizedDescription)")
            cleared = false
        }
        cleared = TripShareStaging.removeStagedShares(in: locations.temporary) && cleared
        if let support = locations.applicationSupport ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first {
            for name in diagnosticsRecorderFileNames {
                cleared = remove(support.appendingPathComponent(name)) && cleared
            }
        } else {
            cleared = false
        }
        return cleared
    }

    /// The Debug build's gate audit and heal log (`DebugGateAudit`,
    /// `DebugHealLog`): place names and travel times. A Release build that
    /// opens a container a Debug build used still holds them, without the
    /// recorder types to clear them, so they are removed by exact name.
    static let diagnosticsRecorderFileNames = ["debug-gate-audit-v1.json", "debug-heal-log-v1.json"]

    /// Removes `url`; true once it is gone, including when it never existed.
    static func remove(_ url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch CocoaError.fileNoSuchFile, CocoaError.fileReadNoSuchFile {
            return true
        } catch {
            logger.error("A private file could not be removed: \(error.localizedDescription)")
            return false
        }
    }

    /// Removes every entry of `directory` whose name `matches`. A missing
    /// folder holds nothing; one that cannot be listed is not clear.
    static func removeEntries(in directory: URL, where matches: (String) -> Bool) -> Bool {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch CocoaError.fileNoSuchFile, CocoaError.fileReadNoSuchFile {
            return true
        } catch {
            logger.error("A private folder could not be listed: \(error.localizedDescription)")
            return false
        }
        var cleared = true
        for name in names where matches(name) {
            cleared = remove(directory.appendingPathComponent(name)) && cleared
        }
        return cleared
    }
}
