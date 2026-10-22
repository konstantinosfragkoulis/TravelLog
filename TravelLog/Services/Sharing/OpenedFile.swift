//
//  OpenedFile.swift
//  TravelLog
//
//  Files the system opens Travel Log with: a shared trip or a backup tapped
//  in Files, or received through AirDrop, Mail or Messages. Files hands over
//  the original in place, security-scoped and read under file coordination;
//  the others hand over a copy in Documents/Inbox, removed once it is read.
//  Neither kind writes anything until the user confirms on its own screen.
//

import Foundation

nonisolated enum OpenedFile {
    enum Kind: Equatable, Sendable {
        /// A shared trip: the shared-trip preview.
        case trip
        /// A backup: Settings › Import & Export, its preview and confirmation.
        case backup
        /// Anything else, such as a `travellog://` link.
        case other
    }

    static func kind(of url: URL) -> Kind {
        guard url.isFileURL else { return .other }
        switch url.pathExtension.lowercased() {
        case TripShareFile.fileExtension: return .trip
        case TripDataExporter.backupFileExtension: return .backup
        default: return .other
        }
    }

    /// Runs `body` with a readable URL for the file, inside its security
    /// scope and a coordinated read, so an original opened in place is not
    /// read while its file provider writes it.
    static func read<T>(_ url: URL, _ body: (URL) throws -> T) throws -> T {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var outcome: Result<T, any Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { readable in
            outcome = Result { try body(readable) }
        }
        if let outcome { return try outcome.get() }
        throw coordinationError ?? CocoaError(.fileReadUnknown)
    }

    /// Where the system copies a file it hands over without opening it in place.
    static var inboxDirectory: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Inbox", isDirectory: true)
    }

    static func isInboxCopy(_ url: URL, inbox: URL? = inboxDirectory) -> Bool {
        guard url.isFileURL, let inbox else { return false }
        let folder = url.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
        return folder.path == inbox.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Removes the system's copy once it is read: a backup holds the whole
    /// history. A file opened in place is the user's own and is never touched.
    static func removeInboxCopy(_ url: URL) {
        guard isInboxCopy(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Delete All Data: any copy still waiting holds history. False while
    /// one could remain, including when the Inbox cannot be listed.
    @discardableResult
    static func removeInboxCopies(in inbox: URL? = inboxDirectory) -> Bool {
        guard let inbox else { return false }
        return PrivateFileCleanup.removeEntries(in: inbox) { _ in true }
    }
}

/// A file opened before the main tabs exist (setup not finished). The main
/// tabs open it when they first appear.
@MainActor
enum OpenedFileHold {
    static var pending: URL?

    static func take() -> URL? {
        defer { pending = nil }
        return pending
    }
}
