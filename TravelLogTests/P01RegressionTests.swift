//
//  P01RegressionTests.swift
//  TravelLogTests
//
//  Delete All Data and the surfaces that publish private data around it:
//  a fixture wipe stays inside its fixture.
//

import Foundation
import os
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Wipe and privacy publication")
struct P01RegressionTests {

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "P01RegressionTests-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    // MARK: - TEST-001

    @Test("a fixture wipe never reaches the host app's sidecars; only the app's container does")
    func fixtureWipeIsIsolated() throws {
        let fixture = try TestSupport.makeInMemoryContainer()
        #expect(DataWipe.SideEffects.resolved(for: fixture).dissolvedQueueFileURL() == nil)
        #expect(DataWipe.SideEffects.resolved(for: fixture).obsoleteStoreFamily(fixture) == nil)
        #expect(DataWipe.SideEffects.resolved(for: AppDelegate.modelContainer)
            .dissolvedQueueFileURL() == DissolvedTripQueue.fileURL())

        // A default fixture wipe runs no notification or queue effect of the host.
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = ModelContext(fixture)
        context.insert(Trip(startDate: Date(timeIntervalSinceReferenceDate: 0)))
        try context.save()
        #expect(DataWipe.execute(container: fixture, defaults: defaults))
        #expect(try ModelContext(fixture).fetchCount(FetchDescriptor<Trip>()) == 0)
    }

    // MARK: - WIPE-001

    /// Scratch folders standing in for tmp, Documents/Inbox and Application Support.
    private func scratchLocations() throws -> (locations: PrivateFileCleanup.Locations, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("P01RegressionTests-\(UUID().uuidString)", isDirectory: true)
        let locations = PrivateFileCleanup.Locations(
            temporary: root.appendingPathComponent("tmp", isDirectory: true),
            inbox: root.appendingPathComponent("Inbox", isDirectory: true),
            applicationSupport: root.appendingPathComponent("Support", isDirectory: true))
        for folder in [locations.temporary, locations.inbox, locations.applicationSupport].compactMap({ $0 }) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return (locations, root)
    }

    private func removeScratch(_ root: URL) {
        if let paths = FileManager.default.enumerator(atPath: root.path) {
            for case let path as String in paths {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent(path).path)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    private struct Seeded {
        let staged: URL
        let restoreCopy: URL
        let share: URL
        let inboxCopy: URL
        let ledger: URL
        let unrelated: URL
        var personal: [URL] { [staged, restoreCopy, share, inboxCopy, ledger] }
    }

    private func seed(_ locations: PrivateFileCleanup.Locations) throws -> Seeded {
        let fm = FileManager.default
        let staged = locations.temporary.appendingPathComponent(
            "\(TripDataExporter.exportFilePrefix)2001-01-01.\(TripDataExporter.backupFileExtension)")
        let restoreCopy = locations.temporary.appendingPathComponent(
            "\(TripDataExporter.restoreStagingPrefix)\(UUID().uuidString).json")
        let share = locations.temporary.appendingPathComponent(
            TripShareStaging.directoryPrefix + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: share, withIntermediateDirectories: true)
        let inbox = try #require(locations.inbox)
        let inboxCopy = inbox.appendingPathComponent("Received.travellogtrip")
        let unrelated = locations.temporary.appendingPathComponent("unrelated.txt")
        for url in [staged, restoreCopy, share.appendingPathComponent("Route.gpx"), inboxCopy, unrelated] {
            try Data("history".utf8).write(to: url)
        }
        try SharedTripLedger.markPending(
            [UUID()], shareID: UUID(), title: "Fictional Coast", senderName: "Sender",
            in: locations.applicationSupport)
        let ledger = try #require(SharedTripLedger.fileURL(in: locations.applicationSupport))
        #expect(fm.fileExists(atPath: ledger.path))
        return Seeded(staged: staged, restoreCopy: restoreCopy, share: share,
                      inboxCopy: inboxCopy, ledger: ledger, unrelated: unrelated)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @Test("Delete All Data removes staged copies, Inbox copies and the shared-trip ledger; already gone is cleared")
    func privateFilesAreRemoved() throws {
        let (locations, root) = try scratchLocations()
        defer { removeScratch(root) }
        let seeded = try seed(locations)

        #expect(PrivateFileCleanup.removeDeleteAllDataFiles(at: locations))
        for url in seeded.personal { #expect(!exists(url), "\(url.lastPathComponent) survived") }
        #expect(exists(seeded.unrelated), "only the app's own staged names are removed")

        // Nothing left, and folders that were never created: both are clear.
        #expect(PrivateFileCleanup.removeDeleteAllDataFiles(at: locations))
        let missing = root.appendingPathComponent("missing", isDirectory: true)
        #expect(PrivateFileCleanup.removeDeleteAllDataFiles(at: .init(
            temporary: missing, inbox: missing, applicationSupport: missing)))
    }

    @Test("a private file that cannot be removed fails the cleanup, and every other one is still removed",
          arguments: ["inbox", "ledger", "share", "export"])
    func privateFileFailureIsReported(target: String) throws {
        let (locations, root) = try scratchLocations()
        defer { removeScratch(root) }
        let seeded = try seed(locations)
        // A read-only folder: what it holds cannot be unlinked.
        let lockedFolder: URL
        let kept: [URL]
        switch target {
        case "inbox":
            lockedFolder = try #require(locations.inbox); kept = [seeded.inboxCopy]
        case "ledger":
            lockedFolder = try #require(locations.applicationSupport); kept = [seeded.ledger]
        case "share":
            lockedFolder = seeded.share; kept = [seeded.share]
        default:
            // The staged export sits in a read-only folder of its own name.
            let folder = locations.temporary.appendingPathComponent(
                "\(TripDataExporter.exportFilePrefix)folder.json", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("history".utf8).write(to: folder.appendingPathComponent("inner"))
            lockedFolder = folder; kept = [folder]
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedFolder.path)

        #expect(!PrivateFileCleanup.removeDeleteAllDataFiles(at: locations))
        for url in kept { #expect(exists(url)) }
        for url in seeded.personal where !kept.contains(url) {
            #expect(!exists(url), "\(url.lastPathComponent) must still be removed")
        }
    }

    @Test("a folder that cannot be listed is not an empty one")
    func unlistableFolderIsNotAbsence() throws {
        let (_, root) = try scratchLocations()
        defer { removeScratch(root) }
        let notAFolder = root.appendingPathComponent("Inbox-file")
        try Data("history".utf8).write(to: notAFolder)
        #expect(!OpenedFile.removeInboxCopies(in: notAFolder))
        #expect(!TripShareStaging.removeStagedShares(in: notAFolder))
        #expect(!TripDataExporter.removeStagedExportsChecked(in: notAFolder))
        #expect(!OpenedFile.removeInboxCopies(in: nil))
    }

    // MARK: - NOTE-002

    @Test("the Debug recorders' files go by exact name in every build; nothing else in the folder does")
    func diagnosticsRecorderFilesAreRemoved() throws {
        let (locations, root) = try scratchLocations()
        defer { removeScratch(root) }
        let support = try #require(locations.applicationSupport)
        #if DEBUG
        #expect(PrivateFileCleanup.diagnosticsRecorderFileNames == [DebugGateAudit.fileName, DebugHealLog.fileName])
        #endif
        let recorders = PrivateFileCleanup.diagnosticsRecorderFileNames.map { support.appendingPathComponent($0) }
        let other = support.appendingPathComponent("debug-fm-status-v1.json")
        for url in recorders + [other] { try Data("[]".utf8).write(to: url) }

        #expect(PrivateFileCleanup.removeDeleteAllDataFiles(at: locations))
        for url in recorders { #expect(!exists(url)) }
        #expect(exists(other), "an explicit allowlist, not the whole folder")

        try Data("[]".utf8).write(to: recorders[0])
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: support.path)
        #expect(!PrivateFileCleanup.removeDeleteAllDataFiles(at: locations))
        #expect(exists(recorders[0]))
    }

    // MARK: - PRIV-004

    private func withStatsStorage(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "P01RegressionTests-stats-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        try StatsSnapshotStore.$storageForTesting.withValue(.init(
            directory: directory, defaultsSuiteName: suite
        )) {
            try body(defaults)
        }
    }

    private func saveSnapshot(trips: Int) {
        var aggregates = StatsAggregator.Aggregates()
        aggregates.totalTrips = trips
        StatsSnapshotStore.save(aggregates, generation: StatsSnapshotStore.clearGeneration, languageTag: "en")
    }

    @Test("a wipe the app did not survive past its commit never hydrates the old snapshot")
    func interruptedWipeNeverHydrates() throws {
        try withStatsStorage { defaults in
            saveSnapshot(trips: 3)
            #expect(StatsSnapshotStore.load(languageTag: "en")?.totalTrips == 3)
            let generation = StatsSnapshotStore.clearGeneration
            // The marker another process wrote before its deletes, with a
            // snapshot still on disk under the current generation.
            defaults.set("ended-process", forKey: StatsSnapshotStore.revocationPendingKey)

            #expect(StatsSnapshotStore.load(languageTag: "en") == nil)
            #expect(StatsSnapshotStore.clearGeneration > generation)
            #expect(defaults.object(forKey: StatsSnapshotStore.revocationPendingKey) == nil)
            let snapshotURL = try #require(StatsSnapshotStore.fileURL)
            #expect(!FileManager.default.fileExists(atPath: snapshotURL.path))

            // Revocation finished: fresh aggregates publish and hydrate again.
            saveSnapshot(trips: 0)
            #expect(StatsSnapshotStore.load(languageTag: "en")?.totalTrips == 0)
        }
    }

    @Test("while a wipe's revocation is pending nothing loads or saves, and a compute admitted before it never lands")
    func pendingRevocationRefusesPublication() throws {
        try withStatsStorage { defaults in
            saveSnapshot(trips: 3)
            let admitted = try #require(StatsSnapshotStore.reserveSave(generation: StatsSnapshotStore.clearGeneration))
            let generation = StatsSnapshotStore.clearGeneration

            StatsSnapshotStore.beginRevocation()
            #expect(defaults.string(forKey: StatsSnapshotStore.revocationPendingKey) != nil)
            #expect(StatsSnapshotStore.load(languageTag: "en") == nil)
            #expect(StatsSnapshotStore.reserveSave(generation: StatsSnapshotStore.clearGeneration) == nil)
            var stale = StatsAggregator.Aggregates()
            stale.totalTrips = 3
            StatsSnapshotStore.save(stale, request: admitted, languageTag: "en")
            let snapshotURL = try #require(StatsSnapshotStore.fileURL)
            #expect(!FileManager.default.fileExists(atPath: snapshotURL.path))

            // The same process finishes it: no relaunch recovery is owed.
            #expect(StatsSnapshotStore.finishRevocation())
            #expect(defaults.object(forKey: StatsSnapshotStore.revocationPendingKey) == nil)
            #expect(StatsSnapshotStore.clearGeneration == generation + 2)
            #expect(StatsSnapshotStore.load(languageTag: "en") == nil)
        }
    }

    @Test("the wipe begins the revocation before its deletes and finishes it after the commit or the rollback",
          arguments: [true, false])
    func wipeRevokesAroundTheCommit(commits: Bool) throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(Trip(startDate: Date(timeIntervalSinceReferenceDate: 0)))
        try context.save()
        var events: [String] = []
        var effects = DataWipe.SideEffects.isolated
        effects.beginSnapshotRevocation = {
            let trips = (try? ModelContext(container).fetchCount(FetchDescriptor<Trip>())) ?? -1
            events.append("begin:\(trips)")
        }
        effects.finishSnapshotRevocation = {
            let trips = (try? ModelContext(container).fetchCount(FetchDescriptor<Trip>())) ?? -1
            events.append("finish:\(trips)")
        }

        let wiped = DataWipe.execute(
            container: container, defaults: defaults, sideEffects: effects,
            beforeCommit: { if !commits { throw CocoaError(.fileWriteUnknown) } },
            afterCommit: { events.append("afterCommit") })
        #expect(wiped == commits)
        #expect(events == (commits ? ["begin:1", "finish:0", "afterCommit"] : ["begin:1", "finish:1"]))
    }

    // MARK: - SEARCH-001

    @Test("Where Was I and Next Trip refuse an answer a deletion overtook, and answer when none did")
    func overtakenIntentAnswersAreRefused() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let suite = "P01RegressionTests-intents-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        let day = Date(timeIntervalSinceReferenceDate: 86_400 * 400)
        try await StatsSnapshotStore.$storageForTesting.withValue(.init(
            directory: directory, defaultsSuiteName: suite
        )) {
            let captured = StatsSnapshotStore.clearGeneration
            let loaded = try await WhereWasIFetcher.load(
                on: day, through: nil, container: container, calendar: .current,
                isPersistentStore: true, clearGeneration: captured)
            #expect(loaded.visits.isEmpty)
            #expect(try await NextPlannedTripIntent.nextJourney(
                container: container, now: day, clearGeneration: captured) == nil)

            // Delete All Data (or Delete Calendar Data) lands while they run.
            StatsSnapshotStore.clear()
            await #expect(throws: IntentDataError.unavailable) {
                try await WhereWasIFetcher.load(
                    on: day, through: nil, container: container, calendar: .current,
                    isPersistentStore: true, clearGeneration: captured)
            }
            await #expect(throws: IntentDataError.unavailable) {
                try await NextPlannedTripIntent.nextJourney(
                    container: container, now: day, clearGeneration: captured)
            }
            // A request begun after it reads the current store.
            #expect(try await WhereWasIFetcher.load(
                on: day, through: nil, container: container, calendar: .current,
                isPersistentStore: true).visits.isEmpty)
        }
    }

    // MARK: - MAP-004

    @Test("only a committed wipe revokes the map, even when a later cleanup fails",
          arguments: [(true, true), (true, false), (false, true)])
    func committedWipeRevokesMap(commits: Bool, cleanupSucceeds: Bool) throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        var revocations = 0
        var effects = DataWipe.SideEffects.isolated
        effects.revokeMapSnapshot = { revocations += 1 }
        effects.removePrivateFiles = { cleanupSucceeds }

        let wiped = DataWipe.execute(
            container: container, defaults: defaults, sideEffects: effects,
            beforeCommit: { if !commits { throw CocoaError(.fileWriteUnknown) } })
        #expect(wiped == (commits && cleanupSucceeds))
        #expect(revocations == (commits ? 1 : 0))

        // The application's effect moves the epoch the map compares against.
        let epoch = MapSnapshotRevocation.shared.epoch
        DataWipe.SideEffects.application.revokeMapSnapshot()
        #expect(MapSnapshotRevocation.shared.epoch == epoch + 1)
    }

    // MARK: - WIPE-003

    @Test("clearing the shared-trip ledger tells an open list, which can read it at once; a failed clear keeps it",
          .timeLimit(.minutes(1)))
    func ledgerClearIsAnnounced() throws {
        let (locations, root) = try scratchLocations()
        defer { removeScratch(root) }
        let directory = try #require(locations.applicationSupport)
        try SharedTripLedger.markPending(
            [UUID()], shareID: UUID(), title: "Fictional Coast", senderName: nil, in: directory)

        // Delivered on the posting thread, as the Settings list receives it.
        let seen = OSAllocatedUnfairLock(initialState: [Int]())
        let observer = NotificationCenter.default.addObserver(
            forName: SharedTripLedger.didChangeNotification, object: nil, queue: nil
        ) { _ in
            let count = (try? SharedTripLedger.load(in: directory).count) ?? -1
            seen.withLock { $0.append(count) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try SharedTripLedger.clear(in: directory)
        #expect(seen.withLock { $0 }.contains(0), "the open list reloads to empty")
        // Already gone: still a clear, still announced.
        try SharedTripLedger.clear(in: directory)

        try SharedTripLedger.markPending(
            [UUID()], shareID: UUID(), title: "Fictional Coast", senderName: nil, in: directory)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        #expect(throws: (any Error).self) { try SharedTripLedger.clear(in: directory) }
        #expect(try SharedTripLedger.load(in: directory).count == 1)
    }

    // MARK: - SHARE-005

    @Test("a staging that finishes after its share sheet was cancelled is removed at once")
    func lateStagingAfterCancelIsRemoved() throws {
        let (locations, root) = try scratchLocations()
        defer { removeScratch(root) }
        func staged() throws -> TripShareStaging.Staged {
            let folder = locations.temporary.appendingPathComponent(
                TripShareStaging.directoryPrefix + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let item = folder.appendingPathComponent("Route.gpx")
            try Data("fixes".utf8).write(to: item)
            return TripShareStaging.Staged(directory: folder, items: [item], omitted: 0)
        }
        let lifetime = TripShareStaging.Lifetime()
        let presented = try staged()
        #expect(lifetime.adopt(presented)?.directory == presented.directory)
        #expect(exists(presented.directory), "a sheet still up keeps what it will share")

        lifetime.end()
        let late = try staged()
        #expect(lifetime.adopt(late) == nil)
        #expect(!exists(late.directory))
    }

    // MARK: - MAP-002

    private func hexRow(_ cell: String, _ iso: String?, lastVisited: Double) -> HexVisitSnapshot {
        HexVisitSnapshot(
            h3Index: cell, locality: nil, country: iso.map { "Country \($0)" }, isoCountryCode: iso,
            firstVisited: Date(timeIntervalSinceReferenceDate: 0),
            lastVisited: Date(timeIntervalSinceReferenceDate: lastVisited), visitCount: 1,
            centerLatitude: 44.3, centerLongitude: 12.9)
    }

    private let square: HexMapDataLoader.BoundaryLookup = { _ in
        [(44.3, 12.9), (44.4, 12.9), (44.4, 13.0), (44.3, 13.0)]
    }

    @Test("a border cell whose rows carry two countries routes from either Stats country to its one drawn cell")
    func mapKeepsEveryCountryOfACell() throws {
        // Newest row first, as the loader fetches them.
        let snapshot = try HexMapDataLoader.buildSnapshot(inputs: .init(
            transit: [], realHexes: [],
            rows: [hexRow("border", "SE", lastVisited: 2), hexRow("border", "NO", lastVisited: 1),
                   hexRow("inland", "NO", lastVisited: 0)]),
            boundaryForHex: square)
        #expect(snapshot.overlays.map(\.id) == ["border", "inland"])
        #expect(snapshot.rows.map(\.isoCountryCode) == ["SE", "NO"], "one display row per cell")
        #expect(snapshot.countryCodes == ["border": ["SE", "NO"]])

        let rows = HexMapDataLoader.highlightRows(snapshot.rows, countryCodes: snapshot.countryCodes)
        #expect(HexHighlightRequest.country(code: "NO", name: nil).matchingHexIndices(in: rows) == ["border", "inland"])
        #expect(HexHighlightRequest.country(code: "SE", name: nil).matchingHexIndices(in: rows) == ["border"])
        #expect(HexHighlightRequest.newThisYear.matchingHexIndices(
            in: rows, now: Date(timeIntervalSinceReferenceDate: 0)) == ["border", "inland"])

        // Singletons, same-country twins and a nil-labelled twin add nothing.
        let plain = try HexMapDataLoader.buildSnapshot(inputs: .init(
            transit: [], realHexes: [],
            rows: [hexRow("a", "NO", lastVisited: 2), hexRow("a", "NO", lastVisited: 1),
                   hexRow("b", nil, lastVisited: 1), hexRow("b", "SE", lastVisited: 0),
                   hexRow("c", "SE", lastVisited: 0)]),
            boundaryForHex: square)
        #expect(plain.countryCodes.isEmpty)
        #expect(plain.rows.map(\.isoCountryCode) == ["NO", "SE", "SE"])
    }

    // MARK: - MAP-003

    @Test("a cell with no boundary is neither drawn nor highlighted, counted or framed")
    func unrenderableCellHasNoRow() throws {
        var unrenderable = hexRow("not-a-cell", "GR", lastVisited: 2)
        unrenderable = HexVisitSnapshot(
            h3Index: unrenderable.h3Index, locality: nil, country: "Country GR", isoCountryCode: "GR",
            firstVisited: unrenderable.firstVisited, lastVisited: unrenderable.lastVisited,
            visitCount: 9, centerLatitude: 44.3, centerLongitude: 12.9)
        let snapshot = try HexMapDataLoader.buildSnapshot(inputs: .init(
            transit: [], realHexes: [],
            rows: [unrenderable, hexRow("drawn", "IT", lastVisited: 1)]),
            boundaryForHex: { $0 == "not-a-cell" ? nil : [(44.3, 12.9), (44.4, 12.9), (44.4, 13.0)] })
        #expect(snapshot.rows.map(\.h3Index) == ["drawn"])
        #expect(snapshot.overlays.map(\.id) == ["drawn"])
        #expect(snapshot.maxCount == 1, "the unrenderable count does not scale the others")
        let rows = HexMapDataLoader.highlightRows(snapshot.rows, countryCodes: snapshot.countryCodes)
        #expect(HexHighlightRequest.country(code: "GR", name: nil).matchingHexIndices(in: rows).isEmpty)
        #expect(HexHighlightRequest.country(code: "IT", name: nil).matchingHexIndices(in: rows) == ["drawn"])
    }

    // MARK: - SEARCH-002

    @Test("Where Was I calls a routine place a routine place, never home, in its answer and its card")
    func routinePlaceIsNotHome() {
        func visit(_ category: StayCategory, _ place: String?) -> DayVisit {
            DayVisit(place: place, countryName: nil, flag: nil, category: category, tripID: nil, tripName: nil)
        }
        let day = "March 14, 2028"
        #expect(WhereWasIFetcher.dialogText(visits: [visit(.routine, "Office Town")], dayText: day)
                == "On March 14, 2028, you were at a routine place in Office Town.")
        #expect(WhereWasIFetcher.dialogText(visits: [visit(.routine, nil)], dayText: day)
                == "On March 14, 2028, you were at a routine place.")
        #expect(WhereWasIFetcher.dialogText(visits: [visit(.home, "Home Town")], dayText: day)
                == "On March 14, 2028, you were home in Home Town.")
        #expect(WhereWasISnippetView.placeLine(for: visit(.routine, "Office Town")) == "Routine Place · Office Town")
        #expect(WhereWasISnippetView.placeLine(for: visit(.routine, nil)) == "Routine Place")
        #expect(WhereWasISnippetView.placeLine(for: visit(.home, "Home Town")) == "Home · Home Town")
        // The tiers stay: a destination still answers before a routine place.
        let tier = WhereWasIFetcher.answerTier([visit(.routine, "Office Town"), visit(.destination, "Coast Town")])
        #expect(tier.map(\.category) == [.destination])
    }

    // MARK: - A11Y-003

    @Test("a bare flag row names every country for VoiceOver, those past its last flag too")
    func flagRowsNameEveryCountry() {
        let codes = ["GR", "IT", "FR", "ES", "PT", "MT"]
        let label = TripListSnippetView.countriesLabel(codes)
        let locale = AppLanguagePreference.currentLocale()
        for code in codes {
            #expect(label.contains(locale.localizedString(forRegionCode: code) ?? code))
        }
        #expect(TripListSnippetView.countriesLabel(["GR"]) != TripListSnippetView.countriesLabel(["IT"]),
                "two trips with the same custom title and dates still differ")
        #expect(TripListSnippetView.countriesLabel([]).isEmpty)
    }

    @Test("a committed wipe that leaves a private file reports failure and still clears the queue")
    func privateFileResidueFailsTheWipe() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(Trip(startDate: Date(timeIntervalSinceReferenceDate: 0)))
        try context.save()
        var queueCleared = false
        var effects = DataWipe.SideEffects.isolated
        effects.removePrivateFiles = { false }
        effects.clearDissolvedQueue = { queueCleared = true }

        #expect(!DataWipe.execute(container: container, defaults: defaults, sideEffects: effects))
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Trip>()) == 0,
                "the store deletion committed")
        #expect(queueCleared)
    }
}
