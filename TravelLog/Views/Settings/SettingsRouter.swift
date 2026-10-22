//
//  SettingsRouter.swift
//  TravelLog
//
//  The Settings tab's navigation path, so a backup opened from Files or
//  AirDrop can show Import & Export, where `SettingsImportExportView` runs
//  the same preview and confirmation as its own file picker.
//

import Foundation

enum SettingsRoute: Hashable {
    case importExport
}

@MainActor @Observable
final class SettingsRouter {
    static let shared = SettingsRouter()

    var path: [SettingsRoute] = []
    /// An opened backup waiting for Import & Export, which clears it.
    var openedBackup: URL?

    func openBackup(_ url: URL) {
        openedBackup = url
        if path != [.importExport] { path = [.importExport] }
    }

    func takeOpenedBackup() -> URL? {
        defer { openedBackup = nil }
        return openedBackup
    }
}
