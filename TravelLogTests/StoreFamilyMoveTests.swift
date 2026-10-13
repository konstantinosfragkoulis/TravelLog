//
//  StoreFamilyMoveTests.swift
//  TravelLogTests
//
//  Pins for the production store opener's App-Group move
//  (`AppDelegate.migrateStoreFamily`). The load-bearing contract is ALL-OR-NOTHING: copying the
//  main file without its `-wal` ships a store missing
//  committed-but-not-checkpointed transactions, so a partial copy must roll
//  back completely and leave the old store as the source of truth for a
//  retry next launch — and the copy order is
//  crash-safe: the main file appears LAST, so a process kill mid-family
//  can never leave an adoptable main-without-WAL destination. Failure is
//  injected with real file-system state (source permissions, planted
//  crashed-attempt leftovers) — no mocks.
//

import Testing
import Foundation
import os
@testable import TravelLog

@MainActor
struct StoreFamilyMoveTests {

    private let logger = Logger(subsystem: "com.travellog.tests", category: "StoreFamilyMove")

    /// Fresh sandbox with distinct "default container" and "app group"
    /// directories per test.
    private func makeSandbox() throws -> (old: URL, new: URL, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-move-\(UUID().uuidString)")
        let old = root.appendingPathComponent("default/TravelLog.store")
        let new = root.appendingPathComponent("group/Library/Application Support/TravelLog.store")
        try FileManager.default.createDirectory(
            at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (old, new, root)
    }

    private func write(_ content: String, at url: URL) throws {
        try Data(content.utf8).write(to: url)
    }

    private func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test("failed moves open the legacy store for this session; all other outcomes open the App Group")
    func openingLocationPolicy() {
        #expect(AppDelegate.storeOpeningLocation(after: .directoryCreationFailed) == .legacy)
        #expect(AppDelegate.storeOpeningLocation(after: .rolledBack) == .legacy)
        #expect(AppDelegate.storeOpeningLocation(after: .noSourceStore) == .appGroup)
        #expect(AppDelegate.storeOpeningLocation(after: .destinationExists) == .appGroup)
        #expect(AppDelegate.storeOpeningLocation(after: .migrated) == .appGroup)
    }

    @Test("fresh install: no source store → no-op, destination untouched")
    func freshInstallIsNoOp() throws {
        let (old, new, root) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        let outcome = AppDelegate.migrateStoreFamily(from: old, to: new, logger: logger)
        #expect(outcome == .noSourceStore)
        #expect(!FileManager.default.fileExists(atPath: new.path))
    }

    @Test("already migrated: destination exists → source and destination both untouched")
    func existingDestinationIsNeverOverwritten() throws {
        let (old, new, root) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("OLD-MAIN", at: old)
        try FileManager.default.createDirectory(
            at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write("CURRENT-GROUP-STORE", at: new)
        // The LIVE store's own sidecar: the crashed-attempt sweep must never
        // run when a destination main exists — deleting a live `-wal` here
        // would drop committed transactions.
        try write("CURRENT-LIVE-WAL", at: URL(fileURLWithPath: new.path + "-wal"))

        let outcome = AppDelegate.migrateStoreFamily(from: old, to: new, logger: logger)
        #expect(outcome == .destinationExists)
        // The App-Group store is the LIVE one once it exists — clobbering it
        // with the stale pre-migration backup would be data loss.
        #expect(read(new) == "CURRENT-GROUP-STORE")
        #expect(read(URL(fileURLWithPath: new.path + "-wal")) == "CURRENT-LIVE-WAL",
                "the live destination WAL must survive untouched — the leftover sweep may only run when no destination main exists")
        #expect(read(old) == "OLD-MAIN", "the backup source must stay untouched")
    }

    @Test("happy path: main + -wal + -shm all copied byte-identical, source preserved as backup")
    func fullFamilyCopies() throws {
        let (old, new, root) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("MAIN", at: old)
        try write("WAL-TRANSACTIONS", at: URL(fileURLWithPath: old.path + "-wal"))
        try write("SHM", at: URL(fileURLWithPath: old.path + "-shm"))

        let outcome = AppDelegate.migrateStoreFamily(from: old, to: new, logger: logger)
        #expect(outcome == .migrated)
        #expect(read(new) == "MAIN")
        #expect(read(URL(fileURLWithPath: new.path + "-wal")) == "WAL-TRANSACTIONS",
                "the WAL holds committed-but-not-checkpointed data — it MUST travel with the main file")
        #expect(read(URL(fileURLWithPath: new.path + "-shm")) == "SHM")
        // Backup semantics: the old family stays in place.
        #expect(read(old) == "MAIN")
        #expect(FileManager.default.fileExists(atPath: old.path + "-wal"))
    }

    @Test("checkpointed store: main only (no -wal/-shm) still migrates, no stray sidecars minted")
    func mainOnlyStoreMigrates() throws {
        let (old, new, root) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("MAIN", at: old)

        let outcome = AppDelegate.migrateStoreFamily(from: old, to: new, logger: logger)
        #expect(outcome == .migrated)
        #expect(read(new) == "MAIN")
        #expect(!FileManager.default.fileExists(atPath: new.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: new.path + "-shm"))
    }

    @Test("the acknowledged photo checkpoint moves with its database")
    func photoCheckpointMovesWithStore() throws {
        let (old, new, root) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("MAIN", at: old)
        let suffix = ".photo-import-checkpoint.json"
        try write("ACKNOWLEDGED-CHECKPOINT", at: URL(fileURLWithPath: old.path + suffix))
        #expect(AppDelegate.migrateStoreFamily(from: old, to: new, logger: logger) == .migrated)
        #expect(read(URL(fileURLWithPath: new.path + suffix)) == "ACKNOWLEDGED-CHECKPOINT")
    }

    @Test("all-or-nothing: a mid-family copy failure rolls back the partial copy so next launch retries")
    func partialCopyRollsBack() throws {
        let (old, new, root) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("MAIN", at: old)
        try write("WAL-TRANSACTIONS", at: URL(fileURLWithPath: old.path + "-wal"))
        try write("SHM", at: URL(fileURLWithPath: old.path + "-shm"))

        // Failure injection with real file-system state: strip read
        // permission from the SOURCE main file, so the (sidecars-first)
        // family copy succeeds through `-wal`/`-shm` and then fails on the
        // main file — the dangerous half-copied state.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: old.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: old.path)
        }

        let outcome = AppDelegate.migrateStoreFamily(from: old, to: new, logger: logger)
        #expect(outcome == .rolledBack)
        // The copied sidecars must be GONE — surviving orphans would collide
        // with (or be mistaken for part of) the retried copy next launch.
        #expect(!FileManager.default.fileExists(atPath: new.path))
        #expect(!FileManager.default.fileExists(atPath: new.path + "-wal"),
                "partial sidecar copy survived rollback")
        #expect(!FileManager.default.fileExists(atPath: new.path + "-shm"),
                "partial -shm copy survived rollback")
        // Source family untouched — still the source of truth for the retry.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: old.path)
        #expect(read(old) == "MAIN")
        #expect(read(URL(fileURLWithPath: old.path + "-wal")) == "WAL-TRANSACTIONS")
    }

    @Test("a crash-interrupted attempt (sidecars copied, no main) is swept and fully retried")
    func crashedAttemptLeftoversAreSweptAndRetried() throws {
        let (old, new, root) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("MAIN", at: old)
        try write("FRESH-WAL", at: URL(fileURLWithPath: old.path + "-wal"))

        // The on-disk state a process kill can leave under the crash-safe
        // order: destination sidecars (from the interrupted attempt) with NO
        // destination main. The retry must not adopt or trip over them.
        try FileManager.default.createDirectory(
            at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write("STALE-WAL-FROM-CRASHED-ATTEMPT", at: URL(fileURLWithPath: new.path + "-wal"))
        try write("STALE-TMP", at: URL(fileURLWithPath: new.path + ".tmp"))

        let outcome = AppDelegate.migrateStoreFamily(from: old, to: new, logger: logger)
        #expect(outcome == .migrated)
        #expect(read(new) == "MAIN")
        #expect(read(URL(fileURLWithPath: new.path + "-wal")) == "FRESH-WAL",
                "the retry must re-copy the CURRENT source WAL, not adopt the stale leftover")
        #expect(!FileManager.default.fileExists(atPath: new.path + ".tmp"))
    }
}
