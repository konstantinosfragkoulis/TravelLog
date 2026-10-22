//
//  TripDataExporter+Cleanup.swift
//  TravelLog
//
//  Delete All Data's checked removal of staged export and restore copies.
//

import Foundation

extension TripDataExporter {

    /// Whether `name` is a copy `removeStagedExports` also removes: a staged
    /// or half-written export, the diagnostics export, or a restore copy.
    nonisolated static func isStagedExportName(_ name: String) -> Bool {
        name == diagnosticsExportFileName
            || (name.hasPrefix(exportFilePrefix)
                && (name.hasSuffix(".json") || name.hasSuffix(".json.gz")
                    || name.hasSuffix(".\(backupFileExtension)") || name.hasSuffix(".partial")))
            || (name.hasPrefix(restoreStagingPrefix)
                && (name.hasSuffix(".json") || name.hasSuffix(".\(lockedCopyExtension)")))
    }

    /// Removes the staged copies in `directory`; false while one could remain.
    nonisolated static func removeStagedExportsChecked(
        in directory: URL = FileManager.default.temporaryDirectory
    ) -> Bool {
        PrivateFileCleanup.removeEntries(in: directory, where: isStagedExportName)
    }
}
