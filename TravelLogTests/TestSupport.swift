//
//  TestSupport.swift
//  TravelLogTests
//
//  Shared helpers for tests that need SwiftData model objects. The
//  `@ModelActor` services (TripClassifier, YearWrappedGenerator) take a
//  `ModelContainer`; a throwaway store under the temporary directory lets us
//  instantiate them without CloudKit. The pure `nonisolated` methods under test
//  don't use the actor's context, but the actor still needs a container to exist.
//

import Foundation
import SQLite3
import SwiftData
@testable import TravelLog

enum TestSupport {
    /// A fresh, isolated container (throwaway on-disk store, see `temporaryStoreURL`)
    /// holding every `@Model` type at its current (V21) live shape, no migration plan.
    /// The name predates the on-disk store; every call still owns its own state.
    static func makeInMemoryContainer() throws -> ModelContainer {
        TripTitleStore.invalidateHomePlaceIndex()
        let url = temporaryStoreURL()
        if let template = StoreTemplate.shared, (try? template.copy(to: url)) == nil {
            try? FileManager.default.removeItem(at: url)  // a failed copy falls back to a fresh store
        }
        let container = try ModelContainer(
            for: schema, configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
        ContainerRetirement.shared.adopt(container, url: url)
        return container
    }

    static let schema = Schema([
        Stay.self, Trip.self, TripTitleVariant.self,
        LocationPing.self, HexVisit.self,
        Home.self, RoutinePlace.self, PhotoImportState.self,
        HiddenPhoto.self, PinnedPhoto.self, YearWrapped.self,
        PlannedTrip.self, HomeAreaOverride.self, Visit.self,
        TemporaryHome.self,
    ])

    /// A unique on-disk store per container. In-memory stores all map to the same
    /// `/dev/null` URL and, since iOS 27, concurrent saves across them abort the test
    /// host with `NSInternalInconsistencyException: No eligible connection available`.
    /// The directory is recreated when the test host starts, so stores never accumulate across runs.
    static func temporaryStoreURL() -> URL {
        storeDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
    }

    private static let storeDirectory: URL = {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TravelLogTests-stores", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()
}

// MARK: - Close stores off the test's own time

/// Keeps the 16 newest test containers and drops older ones on a background
/// queue. Closing a store (WAL checkpoint and teardown, 7-10 ms) then runs
/// beside the next tests instead of inside each one. When that background drop
/// was the last reference, the store family is deleted one batch later, so a
/// run no longer leaves ~3,000 families (589 MB) for the next host start to
/// delete (~1.3 s inside the first container test). A container something
/// else still holds keeps its files. At most two batches are queued and the
/// caller never waits: with both slots busy (a loaded machine) the overflow is
/// released on the calling thread and keeps its files, as before this queue.
private final class ContainerRetirement: @unchecked Sendable {
    static let shared = ContainerRetirement()
    private final class Held {
        var container: ModelContainer?
        let url: URL
        init(_ container: ModelContainer, _ url: URL) { self.container = container; self.url = url }
    }
    private let lock = NSLock()
    private var held: [Held] = []
    private var closed: [URL] = []
    private let queue = DispatchQueue(label: "TestSupport.retirement", qos: .userInitiated)
    private let slots = DispatchSemaphore(value: 2)

    func adopt(_ container: ModelContainer, url: URL) {
        lock.lock()
        held.append(Held(container, url))
        let overflow = held.count > 16 ? [held.removeFirst()] : []
        lock.unlock()
        guard !overflow.isEmpty else { return }
        guard slots.wait(timeout: .now()) == .success else {
            for entry in overflow { entry.container = nil }
            return
        }
        queue.async { self.retire(overflow); self.slots.signal() }
    }

    private func retire(_ batch: [Held]) {
        let previous = closed
        closed = []
        for entry in batch {
            var unique = false
            do {
                guard var container = entry.container else { continue }
                entry.container = nil
                unique = isKnownUniquelyReferenced(&container)
            }
            if unique { closed.append(entry.url) }
        }
        // Assumes nothing else opens a factory store's URL (no test does).
        for url in previous {
            for suffix in ["", "-wal", "-shm", ".photo-import-checkpoint.json"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
    }
}

// MARK: - Copy an empty store instead of creating one

/// An empty store created once the same way, checkpointed into its main file.
/// Each copy gets its own Z_METADATA.Z_UUID (the store identity that history
/// tokens and PersistentIdentifier.storeIdentifier carry; Z_PLIST has no
/// NSStoreUUID), patched in place: the only 36-byte occurrence in the file.
/// A copy has the same DDL, primary-key rows and metadata as a fresh store
/// and, like a fresh store, its own identity.
/// Any failure building it leaves `shared` nil: every call then creates a
/// fresh store, as before.
private final class StoreTemplate: @unchecked Sendable {
    static let shared = StoreTemplate()
    private let bytes: Data
    private let uuidOffset: Int

    private init?() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TravelLogTests-template.sqlite")
        let wal = url.path + "-wal"
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        let created: Bool = autoreleasepool {
            (try? ModelContainer(for: TestSupport.schema,
                                 configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))) != nil
        }
        guard created else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        let checkpointed = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil) == SQLITE_OK
        var uuid = ""
        var statement: OpaquePointer?
        if checkpointed, sqlite3_prepare_v2(db, "SELECT Z_UUID FROM Z_METADATA", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) {
            uuid = String(cString: text)
        }
        sqlite3_finalize(statement)
        sqlite3_close(db)
        let walBytes = (try? FileManager.default.attributesOfItem(atPath: wal)[.size] as? Int) ?? 0
        guard checkpointed, walBytes == 0, let data = try? Data(contentsOf: url) else { return nil }
        let needle = Data(uuid.utf8)
        guard needle.count == 36, let first = data.range(of: needle),
              data.range(of: needle, in: first.upperBound..<data.endIndex) == nil
        else { return nil }
        bytes = data
        uuidOffset = first.lowerBound
    }

    func copy(to url: URL) throws {
        var copy = bytes
        copy.replaceSubrange(uuidOffset..<(uuidOffset + 36), with: Data(UUID().uuidString.utf8))
        try copy.write(to: url)
    }
}
