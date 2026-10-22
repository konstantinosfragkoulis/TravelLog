//
//  RestoreLatchRearmTests.swift
//  TravelLogTests
//
//  A backup restore is acknowledged only after every restore-sensitive latch
//  is re-armed: the history token is dropped, the calendar revalidation flag
//  is written to the store `CalendarEnricher` reads, and the Spotlight token
//  is invalidated. An interruption before the acknowledgement leaves the
//  restore pending, so the next launch repeats the re-arm. First-run and
//  incomplete sentinel setup still finish without invoking any consumer.
//

import Foundation
import Testing
@testable import TravelLog

/// Resolves Application Support to a throwaway directory, so the restore
/// sentinel can be driven without touching the app container.
private final class RearmSupportDirectory: FileManager {
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

private struct Interrupted: Error {}

/// Counts consumer invocations across the `@Sendable` Spotlight closure.
private final class InvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

@Suite("Restore latch re-arm", .serialized, IsolatedCalendarDefaults())
struct RestoreLatchRearmTests {

    /// Holds the suite name and directory rather than `UserDefaults` and
    /// `FileManager` instances, so the fixture is `Sendable` for the
    /// `@Sendable` Spotlight closure. Each handle resolves the same state.
    private struct Fixture: Sendable {
        let suite: String
        let directory: URL

        var defaults: UserDefaults { UserDefaults(suiteName: suite)! }
        var fileManager: RearmSupportDirectory { RearmSupportDirectory(directory: directory) }

        func tearDown() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeFixture() throws -> Fixture {
        let suite = "restore-rearm-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("restore-rearm-\(UUID().uuidString)", isDirectory: true)
        return Fixture(suite: suite, directory: directory)
    }

    private var calendarDefaults: UserDefaults { IsolatedCalendarDefaults.current }

    /// The backup carried the flag but not the excluded marker file.
    private func simulateRestore(_ fixture: Fixture) {
        fixture.defaults.set(true, forKey: RestoreSentinel.flagKey)
        fixture.defaults.set(Data("restored".utf8), forKey: AppDelegate.postImportHistoryTokenKey)
    }

    @Test("every latch is re-armed before the restore is acknowledged")
    func latchesPrecedeAcknowledgement() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        simulateRestore(fixture)
        // Capture the calendar suite name, not a `UserDefaults` instance.
        let calendarSuite = try #require(ForwardGeocoder.TestScope.defaultsSuiteName)
        let counter = InvocationCounter()

        let consumed = await AppDelegate.rearmRestoreSensitiveLatches(
            defaults: fixture.defaults, fileManager: fixture.fileManager,
            invalidateSpotlight: {
                counter.increment()
                #expect(RestoreSentinel.isRestorePending(
                    defaults: fixture.defaults, fileManager: fixture.fileManager),
                        "Spotlight must be invalidated before the acknowledgement")
                #expect(fixture.defaults.data(forKey: AppDelegate.postImportHistoryTokenKey) == nil)
                let calendar = UserDefaults(suiteName: calendarSuite)!
                #expect(calendar.bool(forKey: CalendarEnricher.selectionRevalidationPendingKey))
            })

        #expect(consumed)
        #expect(counter.count == 1)
        #expect(!RestoreSentinel.isRestorePending(
            defaults: fixture.defaults, fileManager: fixture.fileManager))
    }

    @Test("an interrupted re-arm stays pending and repeats on the next launch")
    func interruptedRearmRepeats() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        simulateRestore(fixture)
        let calendar = calendarDefaults
        let counter = InvocationCounter()

        let interrupted = await AppDelegate.rearmRestoreSensitiveLatches(
            defaults: fixture.defaults, fileManager: fixture.fileManager,
            invalidateSpotlight: {
                counter.increment()
                throw Interrupted()
            })
        #expect(!interrupted)
        #expect(RestoreSentinel.isRestorePending(
            defaults: fixture.defaults, fileManager: fixture.fileManager))

        // The calendar consumer ran and cleared its flag before the next launch.
        calendar.removeObject(forKey: CalendarEnricher.selectionRevalidationPendingKey)
        let consumed = await AppDelegate.rearmRestoreSensitiveLatches(
            defaults: fixture.defaults, fileManager: fixture.fileManager,
            invalidateSpotlight: { counter.increment() })
        #expect(consumed)
        #expect(counter.count == 2)
        #expect(calendar.bool(forKey: CalendarEnricher.selectionRevalidationPendingKey))
        #expect(!RestoreSentinel.isRestorePending(
            defaults: fixture.defaults, fileManager: fixture.fileManager))
    }

    @Test("first run creates the sentinel without invoking any consumer")
    func firstRunInitializesWithoutConsumers() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let calendar = calendarDefaults
        let counter = InvocationCounter()

        let consumed = await AppDelegate.rearmRestoreSensitiveLatches(
            defaults: fixture.defaults, fileManager: fixture.fileManager,
            invalidateSpotlight: { counter.increment() })
        #expect(!consumed)
        #expect(counter.count == 0)
        #expect(!calendar.bool(forKey: CalendarEnricher.selectionRevalidationPendingKey))
        #expect(fixture.defaults.bool(forKey: RestoreSentinel.flagKey))
        #expect(FileManager.default.fileExists(
            atPath: fixture.directory.appendingPathComponent(RestoreSentinel.sentinelFilename).path))

        // A normal launch afterwards runs no consumer either.
        let normal = await AppDelegate.rearmRestoreSensitiveLatches(
            defaults: fixture.defaults, fileManager: fixture.fileManager,
            invalidateSpotlight: { counter.increment() })
        #expect(!normal)
        #expect(counter.count == 0)
    }

    @Test("incomplete setup completes without reporting a restore")
    func incompleteSetupCompletes() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        try FileManager.default.createDirectory(
            at: fixture.directory, withIntermediateDirectories: true)
        try Data().write(to: fixture.directory.appendingPathComponent(RestoreSentinel.sentinelFilename))
        let counter = InvocationCounter()

        let consumed = await AppDelegate.rearmRestoreSensitiveLatches(
            defaults: fixture.defaults, fileManager: fixture.fileManager,
            invalidateSpotlight: { counter.increment() })
        #expect(!consumed)
        #expect(counter.count == 0)
        #expect(fixture.defaults.bool(forKey: RestoreSentinel.flagKey))
    }
}
