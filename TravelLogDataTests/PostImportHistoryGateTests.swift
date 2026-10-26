//
//  PostImportHistoryGateTests.swift
//  TravelLogTests
//
//  Pins the persistent-history check that lets the completed-import pass
//  skip when no authored row landed since the last completed pass. Every
//  uncertain state (no token, undecodable token, another schema, another
//  store file, a detected backup restore, pending ghost or orphan
//  observations, a non-persistent store)
//  must run the full pass. Each test owns its store and a throwaway defaults
//  suite, so nothing touches process-global state.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

/// Resolves Application Support to a throwaway directory, so the restore
/// sentinel can be driven without touching the app container.
private final class SupportDirectoryFileManager: FileManager {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
        super.init()
    }

    override func urls(
        for directory: FileManager.SearchPathDirectory,
        in domainMask: FileManager.SearchPathDomainMask
    ) -> [URL] {
        [self.directory]
    }
}

@MainActor
struct PostImportHistoryGateTests {

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "post-import-history-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    private func saveTrip(in container: ModelContainer, author: String? = nil) throws {
        let context = ModelContext(container)
        context.author = author
        context.insert(Trip(startDate: Date(timeIntervalSinceReferenceDate: 0)))
        try context.save()
    }

    private func check(
        _ container: ModelContainer, _ defaults: UserDefaults,
        _ fileManager: FileManager = .default
    ) -> AppDelegate.PostImportHistoryWindow {
        AppDelegate.postImportHistoryWindow(
            modelContainer: container, defaults: defaults, isPersistentStore: true,
            fileManager: fileManager)
    }

    private func recordNewest(_ container: ModelContainer, _ defaults: UserDefaults) throws -> DefaultHistoryToken {
        let newest = try #require(AppDelegate.newestHistoryToken(in: ModelContext(container)))
        AppDelegate.recordPostImportHistoryToken(newest, fullPassAt: .now, defaults: defaults)
        return newest
    }

    @Test("a missing token runs the pass and returns the newest history token")
    func missingTokenRunsAndReturnsNewest() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        try saveTrip(in: container)
        try saveTrip(in: container)

        let result = check(container, defaults)
        #expect(result.mustRun)
        let all = try ModelContext(container).fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>())
        let newest = try #require(all.map(\.token).max())
        #expect(result.latest == newest)
        #expect(AppDelegate.newestHistoryToken(in: ModelContext(container)) == newest)
    }

    @Test("local saves after the token skip the pass and advance the token")
    func localSavesAfterTokenSkipAndAdvance() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        try saveTrip(in: container)
        let stored = try recordNewest(container, defaults)
        try saveTrip(in: container)
        try saveTrip(in: container)

        let result = check(container, defaults)
        #expect(!result.mustRun)
        let latest = try #require(result.latest)
        #expect(latest > stored)
    }

    @Test("an import-authored save after the token runs the pass")
    func importAuthoredSaveRuns() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        try saveTrip(in: container)
        _ = try recordNewest(container, defaults)
        try saveTrip(in: container, author: "NSCloudKitMirroringDelegate.import")

        #expect(check(container, defaults).mustRun)
    }

    @Test("an unfinished pass runs the chain again on an import that merged nothing")
    func unfinishedPassRunsAgainWithoutMergedRows() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        try saveTrip(in: container)
        _ = try recordNewest(container, defaults)
        try saveTrip(in: container, author: "NSCloudKitMirroringDelegate.import")
        let imported = check(container, defaults)
        #expect(imported.mustRun)

        let completed = await HomeAreaHealing.healIfNeeded(defaults: defaults, stages: .init(
            rescue: {}, fingerprint: { nil },
            heal: { _ in
                Issue.record("An unreadable fingerprint must skip healing")
                return .init(moved: 0, failed: false)
            },
            drainParked: { [] }, classify: { true }, generateTitles: {},
            coverage: { [] }, bumpChanges: {}, reloadWidgets: {}))
        #expect(!completed)
        AppDelegate.finishPostImportPass(imported, completed: completed, defaults: defaults)
        #expect(defaults.data(forKey: AppDelegate.postImportHistoryTokenKey) == nil)

        try saveTrip(in: container)
        let retry = check(container, defaults)
        #expect(retry.mustRun)

        let finished = Date.now
        AppDelegate.finishPostImportPass(retry, completed: true, now: finished, defaults: defaults)
        #expect(defaults.object(forKey: AppDelegate.postImportLastFullPassAtKey)
                as? Date == finished)
        try saveTrip(in: container)
        #expect(!check(container, defaults).mustRun)
    }

    @Test("a reset-authored delete after the token runs the pass")
    func resetAuthoredDeleteRuns() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        try saveTrip(in: container)
        _ = try recordNewest(container, defaults)
        let context = ModelContext(container)
        context.author = "NSCloudKitMirroringDelegate.reset"
        for trip in try context.fetch(FetchDescriptor<Trip>()) { context.delete(trip) }
        try context.save()

        #expect(check(container, defaults).mustRun)
    }

    @Test("a token recorded under another schema version runs the pass")
    func schemaMismatchRuns() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        try saveTrip(in: container)
        _ = try recordNewest(container, defaults)
        #expect(!check(container, defaults).mustRun)
        defaults.set("old", forKey: AppDelegate.postImportHistorySchemaKey)

        #expect(check(container, defaults).mustRun)
    }

    @Test("an undecodable token runs the pass")
    func undecodableTokenRuns() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        try saveTrip(in: container)
        defaults.set(Data("x".utf8), forKey: AppDelegate.postImportHistoryTokenKey)
        defaults.set(CurrentTravelLogSchema.versionIdentifier.description,
                     forKey: AppDelegate.postImportHistorySchemaKey)

        #expect(check(container, defaults).mustRun)
    }

    @Test("a token minted by another store file runs the pass")
    func foreignStoreTokenRuns() throws {
        let first = try TestSupport.makeInMemoryContainer()
        let second = try TestSupport.makeInMemoryContainer()
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        try saveTrip(in: first)
        try saveTrip(in: second)
        _ = try recordNewest(first, defaults)
        try saveTrip(in: second)

        #expect(check(second, defaults).mustRun)
    }

    @Test("a day without a full pass runs the pass; a skip does not restamp it")
    func overdueFullPassRuns() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        try saveTrip(in: container)
        let stamped = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let newest = try #require(AppDelegate.newestHistoryToken(in: ModelContext(container)))
        AppDelegate.recordPostImportHistoryToken(newest, fullPassAt: stamped, defaults: defaults)
        try saveTrip(in: container)
        func check(at now: Date) -> (mustRun: Bool, latest: DefaultHistoryToken?) {
            AppDelegate.postImportHistoryCheck(
                modelContainer: container, defaults: defaults, isPersistentStore: true, now: now)
        }

        let soon = check(at: stamped.addingTimeInterval(3_600))
        #expect(!soon.mustRun)
        // The skip path records the token without a full pass stamp.
        AppDelegate.recordPostImportHistoryToken(soon.latest, defaults: defaults)
        #expect(defaults.object(forKey: AppDelegate.postImportLastFullPassAtKey) as? Date == stamped)
        #expect(check(at: stamped.addingTimeInterval(AppDelegate.postImportFullPassInterval)).mustRun)
        // A clock set back before the stamp counts as overdue.
        #expect(check(at: stamped.addingTimeInterval(-60)).mustRun)
        // No stamp at all counts as overdue.
        defaults.removeObject(forKey: AppDelegate.postImportLastFullPassAtKey)
        #expect(check(at: stamped.addingTimeInterval(3_600)).mustRun)
    }

    @Test("completed scoped passes do not postpone the daily full pass")
    func scopedPassesKeepTheFullPassStamp() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        try saveTrip(in: container)
        let stamped = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func window(at now: Date) -> AppDelegate.PostImportHistoryWindow {
            AppDelegate.postImportHistoryWindow(
                modelContainer: container, defaults: defaults, isPersistentStore: true, now: now)
        }
        let full = window(at: stamped)
        #expect(full.titleRepairScope == .all)
        AppDelegate.finishPostImportPass(full, completed: true, now: stamped, defaults: defaults)
        #expect(defaults.object(forKey: AppDelegate.postImportLastFullPassAtKey) as? Date == stamped)

        // A small import every five hours runs a completed pass scoped to its rows.
        for hours in stride(from: 5.0, through: 20, by: 5) {
            try saveTrip(in: container, author: "NSCloudKitMirroringDelegate.import")
            let now = stamped.addingTimeInterval(hours * 3_600)
            let scoped = window(at: now)
            #expect(scoped.mustRun)
            #expect(scoped.titleRepairScope != .all)
            AppDelegate.finishPostImportPass(scoped, completed: true, now: now, defaults: defaults)
            #expect(defaults.object(forKey: AppDelegate.postImportLastFullPassAtKey) as? Date == stamped)
        }

        try saveTrip(in: container, author: "NSCloudKitMirroringDelegate.import")
        let daily = window(at: stamped.addingTimeInterval(25 * 3_600))
        #expect(daily.mustRun)
        #expect(daily.titleRepairScope == .all, "the day's first import after the backstop is due checks every titled trip")
    }

    @Test("a token ahead of the store's own history runs the pass")
    func tokenAheadOfHistoryRuns() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        try saveTrip(in: container)
        let newest = try recordNewest(container, defaults)
        let store = try #require(newest.tokenValue?.keys.first)
        let value = try #require(newest.tokenValue?[store])
        // Same store identifier, a transaction this file has not reached yet.
        // This covers only the window before the file's own history passes the
        // stored value; a backup restore is covered by the restore sentinel.
        let json = try #require(String(data: JSONEncoder().encode(newest), encoding: .utf8))
        let ahead = json.replacingOccurrences(of: ":\(value)", with: ":\(value + 100)")
        try #require(ahead != json)
        defaults.set(Data(ahead.utf8), forKey: AppDelegate.postImportHistoryTokenKey)
        try saveTrip(in: container)

        #expect(check(container, defaults).mustRun)
    }

    @Test("a detected backup restore runs the pass until the launch consumes it")
    func pendingRestoreRuns() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("restore-sentinel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileManager = SupportDirectoryFileManager(directory: directory)
        try saveTrip(in: container)
        let newest = try recordNewest(container, defaults)
        #expect(!check(container, defaults, fileManager).mustRun)

        // The backup carried the flag but not the excluded marker file.
        defaults.set(true, forKey: RestoreSentinel.flagKey)
        let restored = check(container, defaults, fileManager)
        #expect(restored.mustRun)
        #expect(restored.latest == newest)
        // The query does not consume the detection; the launch does.
        #expect(RestoreSentinel.isRestorePending(defaults: defaults, fileManager: fileManager))
        #expect(RestoreSentinel.consumeRestoreDetection(defaults: defaults, fileManager: fileManager))
        #expect(!RestoreSentinel.isRestorePending(defaults: defaults, fileManager: fileManager))
        #expect(!check(container, defaults, fileManager).mustRun)
    }

    @Test("a pending ghost or orphan observation runs the pass", arguments: [
        TripDeduplicator.firstObservedGhostsKey,
        PhotoAnnotationDeduplicator.firstObservedOrphansKey,
        PhotoImportPingDeduplicator.orphanPingFirstObservedKey,
    ])
    func pendingObservationsRun(key: String) throws {
        let container = try TestSupport.makeInMemoryContainer()
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        try saveTrip(in: container)
        _ = try recordNewest(container, defaults)

        defaults.set(["pending": 1.0], forKey: key)
        #expect(check(container, defaults).mustRun)
        defaults.set([String: Double](), forKey: key)
        #expect(!check(container, defaults).mustRun)
    }

    @Test("a ping observation map with no import ping left clears, so the pass can skip again")
    func stalePingObservationClears() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        try saveTrip(in: container)
        _ = try recordNewest(container, defaults)
        defaults.set(["deleted-ping": 1.0], forKey: PhotoImportPingDeduplicator.orphanPingFirstObservedKey)
        #expect(check(container, defaults).mustRun)

        let completed = await PhotoImportPingDeduplicator.readoptOrphanImportPings(
            modelContainer: container, defaults: defaults, importActivityProbe: { false })
        #expect(completed)
        #expect(defaults.object(forKey: PhotoImportPingDeduplicator.orphanPingFirstObservedKey) == nil)
        #expect(!check(container, defaults).mustRun)
    }

    @Test("a non-persistent store always runs the pass and never yields a token")
    func nonPersistentStoreAlwaysRuns() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        try saveTrip(in: container)
        _ = try recordNewest(container, defaults)

        let result = AppDelegate.postImportHistoryCheck(
            modelContainer: container, defaults: defaults, isPersistentStore: false)
        #expect(result.mustRun)
        #expect(result.latest == nil)
    }
}
