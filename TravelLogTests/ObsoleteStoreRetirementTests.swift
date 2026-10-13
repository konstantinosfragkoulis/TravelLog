//
//  ObsoleteStoreRetirementTests.swift
//  TravelLogTests
//
//  Store-family migration keeps the pre-App-Group database as a backup until
//  Delete All Data commits. The wipe then retires that obsolete family on
//  this device, main file first, only when the store it committed to is a
//  different, existing file; a failed or unproven removal keeps a durable
//  marker that the next successful persistent open retries, and that marker
//  stops migration from copying the wiped backup into a missing App Group
//  store. Every test owns a sandbox directory and a throwaway defaults suite.
//

import Foundation
import os
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Obsolete store retirement")
struct ObsoleteStoreRetirementTests {

    private let logger = Logger(subsystem: "com.travellog.tests", category: "ObsoleteStoreRetirement")
    private let pendingKey = DataWipe.legacyStoreRemovalPendingKey

    private struct Sandbox {
        let root: URL
        let legacy: URL
        let group: URL
    }

    private func makeSandbox() throws -> Sandbox {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-retire-\(UUID().uuidString)")
        let legacy = root.appendingPathComponent("default/TravelLog.store")
        let group = root.appendingPathComponent("group/Library/Application Support/TravelLog.store")
        try FileManager.default.createDirectory(
            at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: group.deletingLastPathComponent(), withIntermediateDirectories: true)
        return Sandbox(root: root, legacy: legacy, group: group)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "store-retire-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    private func container(at url: URL) throws -> ModelContainer {
        try ModelContainer(
            for: Stay.self, Trip.self, TripTitleVariant.self,
                 LocationPing.self, HexVisit.self,
                 Home.self, RoutinePlace.self, PhotoImportState.self,
                 HiddenPhoto.self, PinnedPhoto.self, YearWrapped.self,
                 PlannedTrip.self, HomeAreaOverride.self, Visit.self,
                 TemporaryHome.self,
            configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
    }

    private func sidecar(_ url: URL, _ suffix: String) -> URL {
        URL(fileURLWithPath: url.path + suffix)
    }

    private func write(_ content: String, at url: URL) throws {
        try Data(content.utf8).write(to: url)
    }

    private func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// A text stand-in for a legacy family: removal only cares about files.
    private func plantLegacyFamily(at legacy: URL) throws {
        try write("LEGACY-MAIN", at: legacy)
        try write("LEGACY-WAL", at: sidecar(legacy, "-wal"))
        try write("LEGACY-SHM", at: sidecar(legacy, "-shm"))
        try write("LEGACY-JOURNAL", at: sidecar(legacy, ".photo-import-checkpoint.json"))
    }

    private func seededGroupStore(at url: URL) throws -> ModelContainer {
        let group = try container(at: url)
        let context = ModelContext(group)
        context.insert(Trip(startDate: Date(timeIntervalSinceReferenceDate: 0)))
        context.insert(Home(label: "Home", latitude: 37.98, longitude: 23.72,
                            radiusKm: 25, startedAt: Date(timeIntervalSinceReferenceDate: 0)))
        try context.save()
        return group
    }

    private func wipe(
        _ container: ModelContainer, defaults: UserDefaults,
        family: DataWipe.ObsoleteStoreFamily?,
        beforeCommit: () throws -> Void = {},
        removeStoreFile: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) -> Bool {
        DataWipe.execute(
            container: container, defaults: defaults,
            beforeCommit: beforeCommit,
            clearDissolvedQueue: {},
            obsoleteStoreFamily: { _ in family },
            removeStoreFile: removeStoreFile)
    }

    @Test("a real migrated family is retired by a committed wipe")
    func migratedFamilyIsRetiredAfterWipe() throws {
        let box = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        do {
            let legacyStore = try container(at: box.legacy)
            let context = ModelContext(legacyStore)
            context.insert(Trip(startDate: Date(timeIntervalSinceReferenceDate: 0)))
            context.insert(LocationPing(
                timestamp: Date(timeIntervalSinceReferenceDate: 0), latitude: 37.98,
                longitude: 23.72, horizontalAccuracy: 10, h3IndexRes6: "legacy", source: .liveSLC))
            context.insert(Home(label: "Home", latitude: 37.98, longitude: 23.72,
                                radiusKm: 25, startedAt: Date(timeIntervalSinceReferenceDate: 0)))
            try context.save()
        }
        try write("LEGACY-JOURNAL", at: sidecar(box.legacy, ".photo-import-checkpoint.json"))
        #expect(AppDelegate.migrateStoreFamily(from: box.legacy, to: box.group, logger: logger) == .migrated)
        let adjacent = box.legacy.deletingLastPathComponent().appendingPathComponent("restore-sentinel")
        try write("KEEP", at: adjacent)

        let group = try container(at: box.group)
        #expect(wipe(group, defaults: defaults,
                     family: DataWipe.ObsoleteStoreFamily(legacy: box.legacy, active: box.group)))

        for suffix in ["", "-wal", "-shm", ".photo-import-checkpoint.json"] {
            #expect(!exists(sidecar(box.legacy, suffix)), "legacy \(suffix) survived Delete All Data")
        }
        #expect(read(adjacent) == "KEEP", "retirement must never sweep the directory")
        #expect(defaults.object(forKey: pendingKey) == nil)
        let fresh = ModelContext(group)
        #expect(try fresh.fetchCount(FetchDescriptor<Trip>()) == 0)
        #expect(try fresh.fetchCount(FetchDescriptor<LocationPing>()) == 0)
        #expect(try fresh.fetchCount(FetchDescriptor<Home>()) == 1)
        let elsewhere = box.root.appendingPathComponent("elsewhere/TravelLog.store")
        #expect(AppDelegate.migrateStoreFamily(from: box.legacy, to: elsewhere, logger: logger)
                == .noSourceStore)
    }

    @Test("a rolled-back wipe leaves the legacy family byte-identical")
    func failedWipeKeepsLegacyFamily() throws {
        let box = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        try plantLegacyFamily(at: box.legacy)
        let group = try seededGroupStore(at: box.group)

        #expect(!wipe(group, defaults: defaults,
                      family: DataWipe.ObsoleteStoreFamily(legacy: box.legacy, active: box.group),
                      beforeCommit: { throw CocoaError(.fileWriteUnknown) }))
        #expect(read(box.legacy) == "LEGACY-MAIN")
        #expect(read(sidecar(box.legacy, "-wal")) == "LEGACY-WAL")
        #expect(read(sidecar(box.legacy, "-shm")) == "LEGACY-SHM")
        #expect(defaults.object(forKey: pendingKey) == nil)
        #expect(try ModelContext(group).fetchCount(FetchDescriptor<Trip>()) == 1)
    }

    @Test("a failed main removal keeps WAL and SHM intact and retries at launch")
    func mainRemovalFailureRetriesAtLaunch() throws {
        let box = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        try plantLegacyFamily(at: box.legacy)
        let group = try seededGroupStore(at: box.group)
        let legacyMain = box.legacy

        #expect(!wipe(group, defaults: defaults,
                      family: DataWipe.ObsoleteStoreFamily(legacy: box.legacy, active: box.group),
                      removeStoreFile: { url in
                          if url == legacyMain { throw CocoaError(.fileWriteNoPermission) }
                          try FileManager.default.removeItem(at: url)
                      }))
        #expect(try ModelContext(group).fetchCount(FetchDescriptor<Trip>()) == 0,
                "the store wipe itself committed")
        #expect(read(box.legacy) == "LEGACY-MAIN")
        #expect(read(sidecar(box.legacy, "-wal")) == "LEGACY-WAL",
                "a surviving main must keep its committed transactions")
        #expect(read(sidecar(box.legacy, "-shm")) == "LEGACY-SHM")
        #expect(defaults.bool(forKey: pendingKey))

        let retry = AppDelegate.retireObsoleteStoreFamilyIfPending(
            legacyURL: box.legacy, activeURL: box.group, defaults: defaults, logger: logger)
        #expect(retry == .removed)
        for suffix in ["", "-wal", "-shm", ".photo-import-checkpoint.json"] {
            #expect(!exists(sidecar(box.legacy, suffix)))
        }
        #expect(defaults.object(forKey: pendingKey) == nil)
    }

    @Test("sidecar residue after the main is gone is cleaned by the launch retry")
    func sidecarResidueRetries() throws {
        let box = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        try plantLegacyFamily(at: box.legacy)
        try write("GROUP-MAIN", at: box.group)
        defaults.set(true, forKey: pendingKey)
        let wal = sidecar(box.legacy, "-wal")

        let first = AppDelegate.retireObsoleteStoreFamilyIfPending(
            legacyURL: box.legacy, activeURL: box.group, defaults: defaults, logger: logger,
            removeItem: { url in
                if url == wal { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.removeItem(at: url)
            })
        #expect(first == .failed)
        #expect(!exists(box.legacy))
        #expect(read(wal) == "LEGACY-WAL")
        #expect(defaults.bool(forKey: pendingKey))

        let second = AppDelegate.retireObsoleteStoreFamilyIfPending(
            legacyURL: box.legacy, activeURL: box.group, defaults: defaults, logger: logger)
        #expect(second == .removed)
        #expect(!exists(wal))
        #expect(defaults.object(forKey: pendingKey) == nil)
    }

    @Test("a missing authoritative store proves nothing: no removal, marker kept")
    func missingActiveStoreIsUnproven() throws {
        let box = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        try plantLegacyFamily(at: box.legacy)
        defaults.set(true, forKey: pendingKey)

        let outcome = AppDelegate.retireObsoleteStoreFamilyIfPending(
            legacyURL: box.legacy, activeURL: box.group, defaults: defaults, logger: logger)
        #expect(outcome == .authorityUnproven)
        #expect(read(box.legacy) == "LEGACY-MAIN")
        #expect(read(sidecar(box.legacy, "-wal")) == "LEGACY-WAL")
        #expect(defaults.bool(forKey: pendingKey))
    }

    @Test("without a pending marker the launch path removes nothing")
    func noMarkerNoRemoval() throws {
        let box = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        try plantLegacyFamily(at: box.legacy)
        try write("GROUP-MAIN", at: box.group)

        #expect(AppDelegate.retireObsoleteStoreFamilyIfPending(
            legacyURL: box.legacy, activeURL: box.group, defaults: defaults, logger: logger) == nil)
        #expect(read(box.legacy) == "LEGACY-MAIN")
    }

    @Test("a legacy session's wipe never removes the store it wiped")
    func legacySessionStoreSurvives() throws {
        let box = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacySession = try seededGroupStore(at: box.legacy)

        #expect(wipe(legacySession, defaults: defaults,
                     family: DataWipe.ObsoleteStoreFamily(legacy: box.legacy, active: box.legacy)))
        #expect(exists(box.legacy))
        #expect(defaults.object(forKey: pendingKey) == nil,
                "no marker may ever name the authoritative store")
        #expect(try ModelContext(legacySession).fetchCount(FetchDescriptor<Home>()) == 1)
    }

    @Test("a path that resolves to the active store through a symlink is never removed")
    func symlinkedActiveStoreSurvives() throws {
        let box = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        try write("GROUP-MAIN", at: box.group)
        let link = box.root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: box.group.deletingLastPathComponent())
        let aliased = link.appendingPathComponent("TravelLog.store")

        #expect(AppDelegate.removeObsoleteStoreFamily(
            at: aliased, authoritative: box.group, logger: logger) == .activeStore)
        #expect(!AppDelegate.obsoleteStoreFamilyNeedsRetirement(
            legacyURL: aliased, activeURL: box.group))
        #expect(read(box.group) == "GROUP-MAIN")
    }

    @Test("an active journal failure does not stop legacy retirement")
    func journalFailureStillRetiresLegacy() throws {
        let box = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        try plantLegacyFamily(at: box.legacy)
        let group = try seededGroupStore(at: box.group)

        let succeeded = PhotoImportCheckpointJournal.$failClearForTesting.withValue(true) {
            wipe(group, defaults: defaults, family: DataWipe.ObsoleteStoreFamily(legacy: box.legacy, active: box.group))
        }
        #expect(!succeeded, "the journal failure is still reported")
        #expect(!exists(box.legacy))
        #expect(!exists(sidecar(box.legacy, "-wal")))
        #expect(defaults.object(forKey: pendingKey) == nil)
    }

    @Test("a wipe with no legacy family succeeds without a marker")
    func nothingToRetire() throws {
        let box = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let group = try seededGroupStore(at: box.group)

        #expect(wipe(group, defaults: defaults,
                     family: DataWipe.ObsoleteStoreFamily(legacy: box.legacy, active: box.group)))
        #expect(defaults.object(forKey: pendingKey) == nil)
    }

    @Test("a pending retirement never remigrates the wiped backup into a missing destination")
    func pendingRetirementBlocksRemigration() throws {
        let box = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        try plantLegacyFamily(at: box.legacy)

        let outcome = AppDelegate.migrateStoreFamily(
            from: box.legacy, to: box.group, logger: logger, sourceRetirementPending: true)
        #expect(outcome == .sourceRetirementPending)
        #expect(AppDelegate.storeOpeningLocation(after: outcome) == .appGroup)
        #expect(!exists(box.group))
        #expect(!exists(sidecar(box.group, "-wal")))
        #expect(read(box.legacy) == "LEGACY-MAIN")
    }
}
