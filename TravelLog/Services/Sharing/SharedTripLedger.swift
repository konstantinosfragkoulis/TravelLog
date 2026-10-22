//
//  SharedTripLedger.swift
//  TravelLog
//
//  Device-local record of every shared trip added on this device: which share
//  it was, the ping ids it inserted, and the name it carried onto a trip.
//  "Remove Shared Data" deletes exactly those rows. It is not synced: another
//  device holds the rows (they sync) but not this record of them. Delete All
//  Data clears it.
//
//  Ids are written as pending before their gate unit saves and moved to
//  inserted after it commits, so a crash between the two leaves a superset,
//  never a row the ledger forgot. Removal deletes only `.sharedImport` rows,
//  so a pending id that never committed, or an id that turned out to be one of
//  this user's own rows, deletes nothing.
//

import Foundation


nonisolated enum SharedTripLedger {

    struct Record: Codable, Sendable, Equatable, Identifiable {
        var shareID: UUID
        var title: String?
        var senderName: String?
        var firstImportedAt: Date
        var lastImportedAt: Date
        var insertedPingIDs: [UUID] = []
        var pendingPingIDs: [UUID] = []
        /// The sender's name this import put on a trip, and the trip: a later
        /// import updates or clears it only while the trip still carries it.
        var appliedName: String?
        var namedTripID: UUID?

        var id: UUID { shareID }
        var allPingIDs: Set<UUID> { Set(insertedPingIDs).union(pendingPingIDs) }
    }

    enum LedgerError: Error { case unavailable }

    static let fileName = "SharedTripImports.json"
    private static let lock = NSLock()

    static func fileURL(in directory: URL? = nil) -> URL? {
        if let directory { return directory.appendingPathComponent(fileName) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent(fileName)
    }

    /// Newest import first. A missing file is the only empty state; an
    /// unreadable one throws, so a mutation never overwrites it.
    static func load(in directory: URL? = nil) throws -> [Record] {
        lock.lock()
        defer { lock.unlock() }
        return try loadUnlocked(in: directory)
    }

    static func record(for shareID: UUID, in directory: URL? = nil) throws -> Record? {
        try load(in: directory).first { $0.shareID == shareID }
    }

    /// Creates or updates the share's record before a unit writes `ids`.
    static func markPending(
        _ ids: [UUID], shareID: UUID, title: String?, senderName: String?,
        now: Date = .now, in directory: URL? = nil
    ) throws {
        try mutate(in: directory) { records in
            if let index = records.firstIndex(where: { $0.shareID == shareID }) {
                records[index].pendingPingIDs = Array(Set(records[index].pendingPingIDs).union(ids))
                records[index].title = title ?? records[index].title
                records[index].senderName = senderName ?? records[index].senderName
                records[index].lastImportedAt = now
            } else {
                records.append(Record(
                    shareID: shareID, title: title, senderName: senderName,
                    firstImportedAt: now, lastImportedAt: now, pendingPingIDs: ids))
            }
        }
    }

    /// After a unit commits: `inserted` are durable, the rest of `attempted`
    /// were skipped and are no longer pending.
    static func commit(
        inserted: [UUID], attempted: [UUID], shareID: UUID, in directory: URL? = nil
    ) throws {
        try mutate(in: directory) { records in
            guard let index = records.firstIndex(where: { $0.shareID == shareID }) else { return }
            let done = Set(attempted)
            records[index].pendingPingIDs.removeAll { done.contains($0) }
            records[index].insertedPingIDs = Array(Set(records[index].insertedPingIDs).union(inserted))
        }
    }

    static func setAppliedName(
        _ name: String?, tripID: UUID?, shareID: UUID, in directory: URL? = nil
    ) throws {
        try mutate(in: directory) { records in
            guard let index = records.firstIndex(where: { $0.shareID == shareID }) else { return }
            records[index].appliedName = name
            records[index].namedTripID = name == nil ? nil : tripID
        }
    }

    /// Drops a record whose share added nothing durable.
    static func removeIfEmpty(shareID: UUID, in directory: URL? = nil) throws {
        try mutate(in: directory) { records in
            records.removeAll {
                $0.shareID == shareID && $0.insertedPingIDs.isEmpty && $0.pendingPingIDs.isEmpty
                    && $0.appliedName == nil
            }
        }
    }

    static func remove(shareID: UUID, in directory: URL? = nil) throws {
        try mutate(in: directory) { records in records.removeAll { $0.shareID == shareID } }
    }

    /// Delete All Data: the rows it names are gone. Only a removal or an
    /// already-missing file is cleared: `fileExists` is also false for a
    /// file it cannot reach. A cleared ledger is announced like any change,
    /// so a list still on screen empties; a failed one is not.
    static func clear(in directory: URL? = nil) throws {
        try lock.withLock {
            guard let url = fileURL(in: directory) else { throw LedgerError.unavailable }
            do {
                try FileManager.default.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
            }
        }
        postChange()
    }

    // MARK: - File

    private static func loadUnlocked(in directory: URL?) throws -> [Record] {
        guard let url = fileURL(in: directory) else { throw LedgerError.unavailable }
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return try decoder.decode([Record].self, from: Data(contentsOf: url))
            .sorted { $0.lastImportedAt > $1.lastImportedAt }
    }

    private static func mutate(in directory: URL?, _ change: (inout [Record]) -> Void) throws {
        try lock.withLock {
            var records = try loadUnlocked(in: directory)
            change(&records)
            guard let url = fileURL(in: directory) else { throw LedgerError.unavailable }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .deferredToDate
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(records).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        postChange()
    }

    /// Posted after the lock is released: an observer runs on the posting
    /// thread and may read the ledger at once.
    private static func postChange() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static let didChangeNotification = Notification.Name("SharedTripLedgerDidChange")
}
