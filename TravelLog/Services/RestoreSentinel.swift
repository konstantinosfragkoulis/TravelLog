//
//  RestoreSentinel.swift
//  TravelLog
//
//  A backup restore carries UserDefaults but not
//  OS-side state (the CoreSpotlight index, EventKit calendar identifiers,
//  pending local notifications), so device-local latches keep claiming work
//  is done that the restored device has never performed. This sentinel
//  detects the restore so those latches can re-arm once.
//
//  Mechanism: a marker file in Application Support with
//  `isExcludedFromBackup = true`. Excluded files are never written into an
//  iCloud/Finder backup, so after a restore the file is MISSING while the
//  backed-up UserDefaults flag says it was created — that mismatch IS the
//  restore signal. Residual: a direct device-to-device migration clones
//  excluded files too, so it is not detected — acceptable, since cloning
//  also carries more of the OS-side state a backup loses.
//

import Foundation
import os.log

nonisolated enum RestoreSentinel {

    static let flagKey = "restoreSentinelCreated_v1"
    static let sentinelFilename = "restore-sentinel"

    enum Outcome: Equatable {
        /// First launch ever on this container — create the sentinel, no
        /// restore happened.
        case firstRun
        /// The file write completed but exclusion/flag setup did not. Retry
        /// those idempotent steps instead of treating setup as complete.
        case incompleteSetup
        /// Sentinel present — normal launch.
        case normal
        /// Flag says the sentinel was created, but the file is gone: this
        /// container was restored from a backup.
        case restored
    }

    /// Pure decision rule (test seam).
    static func evaluate(fileExists: Bool, flagSet: Bool) -> Outcome {
        if fileExists { return flagSet ? .normal : .incompleteSetup }
        return flagSet ? .restored : .firstRun
    }

    /// Detects a backup restore ONCE per restore: recreates the sentinel
    /// either way, so subsequent launches report `.normal` until the next
    /// restore. Returns `true` exactly when consumers should re-arm their
    /// restore-sensitive latches.
    static func consumeRestoreDetection(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> Bool {
        let logger = Logger(subsystem: "com.travellog.app", category: "RestoreSentinel")
        guard let url = sentinelURL(fileManager: fileManager) else {
            // Application Support unavailable — report no restore rather
            // than re-arming latches on an IO failure.
            logger.error("Could not resolve the sentinel location; skipping restore detection.")
            return false
        }

        let outcome = evaluate(
            fileExists: fileManager.fileExists(atPath: url.path),
            flagSet: defaults.bool(forKey: flagKey)
        )
        switch outcome {
        case .normal:
            return false
        case .incompleteSetup:
            finishSentinelSetup(
                at: url,
                createFile: false,
                defaults: defaults,
                fileManager: fileManager)
            return false
        case .firstRun:
            finishSentinelSetup(
                at: url,
                createFile: true,
                defaults: defaults,
                fileManager: fileManager)
            return false
        case .restored:
            logger.info("Backup restore detected — restore-sensitive latches will re-arm.")
            finishSentinelSetup(
                at: url,
                createFile: true,
                defaults: defaults,
                fileManager: fileManager)
            return true
        }
    }

    /// Non-consuming: is a restore detected and not yet consumed right now?
    /// Unresolvable location reads as no restore, as in the consuming check.
    static func isRestorePending(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let url = sentinelURL(fileManager: fileManager) else { return false }
        return evaluate(
            fileExists: fileManager.fileExists(atPath: url.path),
            flagSet: defaults.bool(forKey: flagKey)
        ) == .restored
    }

    private static func sentinelURL(fileManager: FileManager) -> URL? {
        guard let dir = fileManager.urls(for: .applicationSupportDirectory,
                                         in: .userDomainMask).first else { return nil }
        return dir.appendingPathComponent(sentinelFilename)
    }

    private static func finishSentinelSetup(
        at url: URL,
        createFile: Bool,
        defaults: UserDefaults,
        fileManager: FileManager
    ) {
        do {
            if createFile {
                try fileManager.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data().write(to: url)
            }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = url
            try mutableURL.setResourceValues(values)
            defaults.set(true, forKey: flagKey)
        } catch {
            // The flag is written only after file creation and backup
            // exclusion both succeed. A file that exists while the flag is
            // still false is recognized as incomplete setup and retried next
            // launch; a missing file can never be paired with a newly-set flag.
            Logger(subsystem: "com.travellog.app", category: "RestoreSentinel")
                .error("Could not finish restore sentinel setup: \(error.localizedDescription)")
        }
    }
}
