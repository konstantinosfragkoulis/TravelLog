//
//  DataWipeLeftoversTests.swift
//  TravelLogTests
//
//  Delete All Data's state outside the store. After the commit the wipe
//  removes the app's notifications, the travel-notification state and recap
//  latches, the dismissals that name deleted trips and stays, and the
//  Calendar thin-history probe state; the calendar selection, alert
//  preferences, the iCloud-synced favourites and import fences (shared with
//  devices that were not wiped), and the split-tip ledger stay. A failed commit touches none of it. A Stats
//  snapshot left on disk is reported, the Dec 1 reminder needs early data,
//  and a temporary-home unit acknowledges before its gate lets go.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
private final class WipeSeams {
    var notificationsRemoved = 0
}

@MainActor
private final class HookLog {
    var acknowledgedBeforeRelease: Bool?
}

@MainActor
@Suite("Delete All Data leftovers")
struct DataWipeLeftoversTests {

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "DataWipeLeftoversTests-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    /// Every key the wipe must clear, written as the app writes it, plus the
    /// preferences it must keep.
    private func seedLeftovers(_ defaults: UserDefaults) {
        #expect(NotificationService.claimCountryWelcome(
            "FR", homeCountryCodes: ["GR"], defaults: defaults))
        defaults.set("IT", forKey: "notification_lastCountryCode")
        #expect(NotificationService.welcomeHomeDaysToDeliver(
            isWithinHomeRadius: false, enabled: true, now: .now, zone: .current,
            defaults: defaults) == nil)
        defaults.set(true, forKey: YearWrappedGenerator.scheduledNotificationKey(forYear: 2026))
        defaults.set(true, forKey: YearWrappedGenerator.scheduledNotificationKey(forYear: 2027))
        defaults.set([UUID().uuidString], forKey: FlightCandidateDismissals.defaultsKey)
        TemporaryHomeSuggestion.dismiss(UUID(), defaults: defaults)
        TemporaryHomeCards.dismissEndHint(id: UUID(), backHomeSince: .now, defaults: defaults)
        defaults.set("session|1", forKey: "photoImportBannerDismissedSessionKey")
        defaults.set(Date.now, forKey: HomeAreaHealing.coverageStampedAtKey)
        defaults.set(true, forKey: CalendarEnricher.thinHistoryProbeCompletedKey)
        defaults.set("Work Exchange", forKey: CalendarEnricher.thinHistoryAccountKey)
        defaults.set(true, forKey: CalendarEnricher.thinHistoryTipDismissedKey)

        defaults.set(true, forKey: NotificationService.countryWelcomeEnabledKey)
        defaults.set(false, forKey: NotificationService.welcomeHomeEnabledKey)
        defaults.set("device-A", forKey: ImportFence.deviceIDKey)
        defaults.set([UUID().uuidString], forKey: TripSplitHint.seenTripIDsKey)
        defaults.set(["cal-keep"], forKey: CalendarEnricher.selectedCalendarIDsKey)
    }

    private static let clearedKeys = [
        "notification_lastCountryCode", "notification_notifiedCountryCodes",
        "notification_countryWelcomeTripEpoch", "notification_wasAbroad",
        "notification_departureDate",
        "wrappedNotificationScheduled_2026", "wrappedNotificationScheduled_2027",
        "dismissedFlightCandidates_v1", "temporaryHome.suggestion.notNow",
        "temporaryHome.endHint.notYet", "photoImportBannerDismissedSessionKey",
        "homeAreaCoverageSnapshotAt_v1", "calendarThinHistoryProbe_v1",
        "calendarThinHistoryAccount", "calendarThinHistoryTipDismissed",
    ]

    private func wipe(
        _ container: ModelContainer, _ defaults: UserDefaults, _ seams: WipeSeams,
        commits: Bool = true
    ) -> Bool {
        DataWipe.execute(
            container: container, defaults: defaults,
            beforeCommit: { if !commits { throw CocoaError(.fileWriteUnknown) } },
            clearDissolvedQueue: {},
            clearTemporaryHomeAcknowledgements: {},
            removeAllNotifications: { seams.notificationsRemoved += 1 })
    }

    @Test("a committed wipe clears notifications, their state, recap latches and dismissals, and keeps preferences")
    func committedWipeClearsLeftovers() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        seedLeftovers(defaults)
        let seams = WipeSeams()

        #expect(wipe(container, defaults, seams))

        for key in Self.clearedKeys {
            #expect(defaults.object(forKey: key) == nil, "\(key) survived the wipe")
        }
        #expect(!NotificationService.hasCountryWelcomeDedupState(defaults: defaults))
        #expect(!NotificationService.hasWelcomeHomeDepartureState(defaults: defaults))
        #expect(seams.notificationsRemoved == 1)

        #expect(defaults.object(forKey: NotificationService.countryWelcomeEnabledKey) as? Bool == true)
        #expect(defaults.object(forKey: NotificationService.welcomeHomeEnabledKey) as? Bool == false)
        #expect(defaults.string(forKey: ImportFence.deviceIDKey) == "device-A")
        #expect(defaults.stringArray(forKey: TripSplitHint.seenTripIDsKey)?.count == 1)
        #expect(defaults.stringArray(forKey: CalendarEnricher.selectedCalendarIDsKey) == ["cal-keep"],
                "the calendar selection is consent scope, not wiped history")
    }

    @Test("a rolled-back wipe leaves every leftover and calls none of the clears")
    func failedWipeKeepsLeftovers() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        seedLeftovers(defaults)
        let seams = WipeSeams()

        #expect(!wipe(container, defaults, seams, commits: false))

        for key in Self.clearedKeys {
            #expect(defaults.object(forKey: key) != nil, "\(key) was cleared by a failed wipe")
        }
        #expect(seams.notificationsRemoved == 0)
    }

    // MARK: - Stats snapshot residue

    @Test("a Stats snapshot that cannot be removed is reported; a missing one counts as cleared")
    func statsSnapshotResidueIsReported() throws {
        let suite = "DataWipeLeftoversTests-stats-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        try StatsSnapshotStore.$storageForTesting.withValue(.init(
            directory: directory, defaultsSuiteName: suite
        )) {
            #expect(StatsSnapshotStore.clear(), "no file at all is already clear")

            let url = try #require(StatsSnapshotStore.fileURL)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("old totals".utf8).write(to: url)
            // A read-only directory: the file cannot be unlinked.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o555], ofItemAtPath: directory.path)
            let generation = StatsSnapshotStore.clearGeneration

            #expect(!StatsSnapshotStore.clear())
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(StatsSnapshotStore.clearGeneration == generation + 1,
                    "the residue still cannot hydrate: the generation moved")

            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: directory.path)
            #expect(StatsSnapshotStore.clear())
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    // MARK: - Recap reminder

    @Test("the Dec 1 reminder's data rule: a stay before October of that year, nothing later or elsewhere")
    func recapReminderNeedsEarlyData() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let generator = YearWrappedGenerator(modelContainer: container)
        #expect(try await generator.hasEarlyData(forYear: 2025) == false,
                "a wiped store has no recap to announce")

        func insertStay(month: Int) throws {
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            let start = try #require(utc.date(from: DateComponents(year: 2025, month: month, day: 15)))
            let ctx = ModelContext(container)
            ctx.insert(Stay(
                startTime: start, endTime: start.addingTimeInterval(3_600),
                centroidLatitude: 48.85, centroidLongitude: 2.35, h3IndexRes6: "H",
                pingCount: 2, distanceFromHomeKm: 500, pingIDs: []))
            try ctx.save()
        }

        try insertStay(month: 11)
        #expect(try await generator.hasEarlyData(forYear: 2025) == false,
                "November travel cannot make the year's recap")
        #expect(try await generator.hasEarlyData(forYear: 2024) == false)

        try insertStay(month: 3)
        #expect(try await generator.hasEarlyData(forYear: 2025))
        #expect(try await generator.hasEarlyData(forYear: 2026) == false)
    }

    // MARK: - Temporary-home acknowledgement

    @Test("a temporary-home unit records its acknowledgement before its gate lets go, so a wipe unit cannot clear the file first",
          IsolatedTitleDefaults())
    func temporaryHomeAcknowledgementLandsInsideTheUnit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataWipeLeftoversTests-ack-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let athens: TemporaryHomeFixture.Place = (38.0, 23.8)
        let brussels: TemporaryHomeFixture.Place = (50.85, 4.35)
        let dayZero: Double = -161
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        TemporaryHomeFixture.realHome(ctx, "Athens", at: athens)
        let homeStart = TemporaryHomeFixture.date(dayZero)
        TemporaryHomeFixture.stay(
            ctx, athens, from: homeStart, to: homeStart.addingTimeInterval(0.8 * 86_400), .home,
            hex: "P", pingCount: 2, zone: "GMT")
        let declaration = TemporaryHomeFixture.temporaryHome(
            ctx, "Semester", at: brussels, from: 10 + dayZero, until: nil, zone: "GMT")
        declaration.coverageRevision = 1
        let id = declaration.id
        try ctx.save()
        let classifier = await TemporaryHomeFixture.classifier(
            container, squares: [(1, athens), (2, brussels)])
        let log = HookLog()

        let outcome = await TripClassifier.TemporaryHomeTestHook.$afterUnit.withValue({
            let acknowledged = CoverageReconciliationQueue.Acknowledgements
                .load(from: directory)[id] != nil
            await MainActor.run { log.acknowledgedBeforeRelease = acknowledged }
        }) {
            await StayClassificationInference.TestHook.$availability.withValue(false) {
                await classifier.applyTemporaryHomeChange(
                    temporaryHomeID: id, pinnedTripIDs: { [] },
                    gate: PipelineGate(forTesting: ()), unpinRetired: { _ in },
                    acknowledgementDirectory: directory)
            }
        }

        #expect(outcome.didCommit)
        #expect(log.acknowledgedBeforeRelease == true)
    }
}
