//
//  CalendarSelectionScopeTests.swift
//  TravelLogTests
//
//  An explicit calendar selection never widens to every calendar.
//  Resolution runs against `CalendarEnricher.TestScope.liveCalendars`, so no
//  test here touches EventKit; event queries are counted instead.
//

import EventKit
import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite(.serialized, IsolatedCalendarDefaults())
struct CalendarSelectionScopeTests {

    private typealias Choice = CalendarEnricher.CalendarChoice
    private typealias Entry = CalendarEnricher.SelectedCalendar

    private let travel = Choice(id: "A", title: "Travel", accountTitle: "Google")
    private let work = Choice(id: "B", title: "Work", accountTitle: "Exchange")

    private var defaults: UserDefaults { IsolatedCalendarDefaults.current }

    private func withLiveCalendars<T: Sendable>(
        _ live: [Choice], _ body: () async throws -> T
    ) async rethrows -> T {
        try await CalendarEnricher.TestScope.$authorizationStatus.withValue(.fullAccess) {
            try await CalendarEnricher.TestScope.$liveCalendars.withValue(live) {
                try await body()
            }
        }
    }

    // MARK: - Pure resolution

    @Test("nothing stored reads every calendar")
    func absentSelectionIsAll() {
        let result = CalendarEnricher.resolveSelection(.all, live: [travel, work])
        #expect(result.scope == .all)
        #expect(result.healed == nil)
    }

    @Test("a wholly stale explicit selection reads no calendar, never every calendar")
    func whollyStaleSelectionIsNoneAvailable() {
        let stale = CalendarEnricher.resolveSelection(.explicit([Entry(id: "X")]), live: [travel, work])
        #expect(stale.scope == .noneAvailable)
        #expect(stale.healed == nil)
        let noCalendars = CalendarEnricher.resolveSelection(.explicit([Entry(id: "X")]), live: [])
        #expect(noCalendars.scope == .noneAvailable)
        let unreadable = CalendarEnricher.resolveSelection(.explicit([]), live: [travel, work])
        #expect(unreadable.scope == .noneAvailable)
    }

    @Test("a partly stale selection stays narrow and keeps its stale entry")
    func partlyStaleSelectionStaysNarrow() {
        let stored: [Entry] = [
            Entry(id: "A", accountTitle: "Google", title: "Travel"),
            Entry(id: "X", accountTitle: "iCloud", title: "Family"),
        ]
        let result = CalendarEnricher.resolveSelection(.explicit(stored), live: [travel, work])
        #expect(result.scope == .calendars(["A"]))
        #expect(result.healed == nil)
    }

    @Test("a re-minted identifier re-resolves to its one live calendar by account and title")
    func reMintedIdentifierHealsByFingerprint() {
        let reMinted = Choice(id: "A2", title: "Travel", accountTitle: "Google")
        let result = CalendarEnricher.resolveSelection(
            .explicit([Entry(id: "A", accountTitle: "Google", title: "Travel")]), live: [reMinted, work])
        #expect(result.scope == .calendars(["A2"]))
        #expect(result.healed == [Entry(id: "A2", accountTitle: "Google", title: "Travel")])
    }

    @Test("an ambiguous or already-held fingerprint match does not re-resolve")
    func ambiguousFingerprintStaysStale() {
        let twin1 = Choice(id: "T1", title: "Travel", accountTitle: "Google")
        let twin2 = Choice(id: "T2", title: "Travel", accountTitle: "Google")
        let ambiguous = CalendarEnricher.resolveSelection(
            .explicit([Entry(id: "A", accountTitle: "Google", title: "Travel")]), live: [twin1, twin2])
        #expect(ambiguous.scope == .noneAvailable)
        #expect(ambiguous.healed == nil)

        // The only matching calendar is already selected by its own ID.
        let held = CalendarEnricher.resolveSelection(
            .explicit([Entry(id: "A", accountTitle: "Google", title: "Travel"),
                       Entry(id: "X", accountTitle: "Google", title: "Travel")]), live: [travel])
        #expect(held.scope == .calendars(["A"]))
        #expect(held.healed == nil)
    }

    @Test("a v1 identifier seen live gains its titles")
    func legacyIdentifierGainsFingerprint() {
        let result = CalendarEnricher.resolveSelection(.explicit([Entry(id: "A")]), live: [travel])
        #expect(result.scope == .calendars(["A"]))
        #expect(result.healed == [Entry(id: "A", accountTitle: "Google", title: "Travel")])
    }

    // MARK: - Stored formats

    @Test("stored selection reads v1 as authoritative and never widens an unreadable v2")
    func storedSelectionFormats() throws {
        #expect(CalendarEnricher.storedSelection(in: defaults) == .all)

        defaults.set(["X"], forKey: CalendarEnricher.selectedCalendarIDsKey)
        #expect(CalendarEnricher.storedSelection(in: defaults) == .explicit([Entry(id: "X")]))

        let entries = [Entry(id: "X", accountTitle: "Google", title: "Travel")]
        defaults.set(try JSONEncoder().encode(entries), forKey: CalendarEnricher.selectedCalendarsKey)
        #expect(CalendarEnricher.storedSelection(in: defaults) == .explicit(entries))

        // An older build that re-checked everything wrote an empty v1 list.
        defaults.set([String](), forKey: CalendarEnricher.selectedCalendarIDsKey)
        #expect(CalendarEnricher.storedSelection(in: defaults) == .all)

        defaults.removeObject(forKey: CalendarEnricher.selectedCalendarIDsKey)
        defaults.set(Data("not json".utf8), forKey: CalendarEnricher.selectedCalendarsKey)
        #expect(CalendarEnricher.storedSelection(in: defaults) == .explicit([]))

        CalendarEnricher.saveSelection([], in: defaults)
        #expect(CalendarEnricher.storedSelection(in: defaults) == .all)
    }

    @Test("Settings entries keep a stale calendar's stored titles")
    func selectionEntriesKeepStaleFingerprints() {
        let previous = [Entry(id: "X", accountTitle: "iCloud", title: "Family")]
        let entries = CalendarEnricher.selectionEntries(for: ["A", "X"], choices: [travel, work], previous: previous)
        #expect(entries == [Entry(id: "A", accountTitle: "Google", title: "Travel"),
                            Entry(id: "X", accountTitle: "iCloud", title: "Family")])
    }

    // MARK: - The real choke point

    @Test("eventsOverlapping reads nothing for a wholly stale selection and flags Settings")
    func staleSelectionQueriesNothing() async throws {
        let enricher = CalendarEnricher(modelContainer: try TestSupport.makeInMemoryContainer())
        defaults.set(["X"], forKey: CalendarEnricher.selectedCalendarIDsKey)
        let start = Date(timeIntervalSinceReferenceDate: 850_000_000)

        let events = await withLiveCalendars([travel, work]) {
            await enricher.eventsOverlapping(start: start, end: start.addingTimeInterval(86_400))
        }
        #expect(events.isEmpty)
        #expect(await enricher.eventQueryCountForTesting == 0)
        #expect(defaults.bool(forKey: CalendarEnricher.selectionUnavailableKey))
        #expect(defaults.stringArray(forKey: CalendarEnricher.selectedCalendarIDsKey) == ["X"])

        // The calendar comes back: the same selection queries again.
        _ = await withLiveCalendars([Choice(id: "X", title: "Family", accountTitle: "iCloud"), work]) {
            await enricher.eventsOverlapping(start: start, end: start.addingTimeInterval(86_400))
        }
        #expect(await enricher.eventQueryCountForTesting == 1)
        #expect(!defaults.bool(forKey: CalendarEnricher.selectionUnavailableKey))
    }

    @Test("a detected restore resolves the same way instead of resetting to every calendar")
    func restoreDoesNotWidenSelection() async throws {
        let enricher = CalendarEnricher(modelContainer: try TestSupport.makeInMemoryContainer())
        defaults.set(["X"], forKey: CalendarEnricher.selectedCalendarIDsKey)
        defaults.set(true, forKey: CalendarEnricher.selectionRevalidationPendingKey)
        let start = Date(timeIntervalSinceReferenceDate: 850_000_000)

        _ = await withLiveCalendars([travel, work]) {
            await enricher.eventsOverlapping(start: start, end: start.addingTimeInterval(86_400))
        }
        #expect(await enricher.eventQueryCountForTesting == 0)
        #expect(defaults.stringArray(forKey: CalendarEnricher.selectedCalendarIDsKey) == ["X"])
        #expect(defaults.object(forKey: CalendarEnricher.selectionRevalidationPendingKey) == nil)
        #expect(defaults.bool(forKey: CalendarEnricher.selectionUnavailableKey))
    }

    @Test("a restored selection whose identifiers were re-minted re-resolves by title and is rewritten")
    func reMintedSelectionHealsThroughTheChokePoint() async throws {
        let enricher = CalendarEnricher(modelContainer: try TestSupport.makeInMemoryContainer())
        CalendarEnricher.saveSelection([Entry(id: "A", accountTitle: "Google", title: "Travel")], in: defaults)
        defaults.set(true, forKey: CalendarEnricher.selectionRevalidationPendingKey)
        let reMinted = Choice(id: "A2", title: "Travel", accountTitle: "Google")
        let start = Date(timeIntervalSinceReferenceDate: 850_000_000)

        _ = await withLiveCalendars([reMinted, work]) {
            await enricher.eventsOverlapping(start: start, end: start.addingTimeInterval(86_400))
        }
        #expect(await enricher.eventQueryCountForTesting == 1)
        #expect(defaults.stringArray(forKey: CalendarEnricher.selectedCalendarIDsKey) == ["A2"])
        #expect(CalendarEnricher.storedSelection(in: defaults)
            == .explicit([Entry(id: "A2", accountTitle: "Google", title: "Travel")]))
        #expect(!defaults.bool(forKey: CalendarEnricher.selectionUnavailableKey))

        let snapshot = await withLiveCalendars([reMinted, work]) {
            await enricher.calendarSelectionSnapshot()
        }
        #expect(snapshot.scope == .calendars(["A2"]))
        #expect(Set(snapshot.entries.map(\.id)) == ["A2"])
    }

    @Test("the thin-history probe neither enumerates nor latches while nothing is available")
    func thinHistoryProbeWaitsForAvailableSelection() async throws {
        let enricher = CalendarEnricher(modelContainer: try TestSupport.makeInMemoryContainer())
        defaults.set(["X"], forKey: CalendarEnricher.selectedCalendarIDsKey)
        await withLiveCalendars([travel]) {
            await enricher.runThinHistoryProbeIfNeeded(now: Date(timeIntervalSinceReferenceDate: 850_000_000))
        }
        #expect(!defaults.bool(forKey: CalendarEnricher.thinHistoryProbeCompletedKey))
        #expect(await enricher.eventQueryCountForTesting == 0)
    }

    @Test("a scan over an unavailable selection keeps upcoming rows the stale sweep would delete")
    func unavailableSelectionSkipsReconcile() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let start = Date.now.addingTimeInterval(20 * 86_400)
        let row = PlannedTrip(eventExternalIdentifier: "other-device", eventLocalIdentifier: "other-device",
            title: "Trip to Rome", startDate: start, endDate: start.addingTimeInterval(3 * 86_400),
            isAllDay: false, locationText: nil)
        row.lastSeenAt = Date.now.addingTimeInterval(-10 * 86_400)
        context.insert(row)
        try context.save()
        let enricher = CalendarEnricher(modelContainer: container)
        // Keep the probe away from EventKit in the control scan below.
        defaults.set(true, forKey: CalendarEnricher.thinHistoryProbeCompletedKey)
        defaults.set(["X"], forKey: CalendarEnricher.selectedCalendarIDsKey)

        await withLiveCalendars([travel, work]) {
            await enricher.scanUpcomingTrips()
        }
        #expect(await enricher.eventQueryCountForTesting == 0)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PlannedTrip>()) == 1)

        await withLiveCalendars([travel, work]) {
            await enricher.scanUpcomingTripsUngated()
        }
        #expect(await enricher.eventQueryCountForTesting == 0)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PlannedTrip>()) == 1)

        // Once the selection resolves the scan runs, but this device never saw
        // the other device's event, so an empty scan is no evidence it is gone.
        defaults.set(["A"], forKey: CalendarEnricher.selectedCalendarIDsKey)
        await withLiveCalendars([travel, work]) {
            await enricher.scanUpcomingTrips()
        }
        #expect(await enricher.eventQueryCountForTesting == 1)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PlannedTrip>()) == 1)
    }

    @Test("Delete Calendar Data keeps the explicit selection in both formats")
    func deleteCalendarDataKeepsSelection() async throws {
        let enricher = CalendarEnricher(modelContainer: try TestSupport.makeInMemoryContainer())
        let entries = [Entry(id: "A", accountTitle: "Google", title: "Travel")]
        CalendarEnricher.saveSelection(entries, in: defaults)
        let result = await enricher.deleteAllCalendarData()
        #expect(result.succeeded)
        #expect(CalendarEnricher.storedSelection(in: defaults) == .explicit(entries))
    }

    // MARK: - Settings list state

    @Test("the Settings list shows the unavailable state and leaves it through a live check")
    func settingsSelectionState() {
        #expect(CalendarSelectionView.selectionState(selected: [], live: ["A", "B"]) == .all)
        #expect(CalendarSelectionView.selectionState(selected: ["X"], live: ["A", "B"]) == .noneAvailable)
        #expect(CalendarSelectionView.selectionState(selected: ["X"], live: []) == .noneAvailable)
        let checked = CalendarSelectionView.toggled(["X"], live: ["A", "B"], id: "A")
        #expect(checked == ["A", "X"])
        #expect(CalendarSelectionView.selectionState(selected: checked, live: ["A", "B"]) == .some)
        // Checking the sole live calendar re-checks everything: that is "all".
        let sole = CalendarSelectionView.toggled(["X"], live: ["A"], id: "A")
        #expect(sole == [])
        #expect(CalendarSelectionView.selectionState(selected: sole, live: ["A"]) == .all)
    }

    @Test("an unreadable explicit selection lists no checkmarks, and checking one selects only it")
    func unreadableSelectionListState() async throws {
        let enricher = CalendarEnricher(modelContainer: try TestSupport.makeInMemoryContainer())
        let live: Set<String> = ["A", "B"]

        // Control: nothing stored is every calendar, all checked.
        let allSnapshot = await withLiveCalendars([travel, work]) { await enricher.calendarSelectionSnapshot() }
        let all = CalendarSelectionView.initialSelection(from: allSnapshot)
        #expect(all == nil)
        #expect(CalendarSelectionView.selectionState(selection: all, live: live) == .all)
        #expect(CalendarSelectionView.isIncluded("A", in: all))

        // Unreadable v2, no v1: the engine reads nothing, and so must the list.
        defaults.set(Data("not json".utf8), forKey: CalendarEnricher.selectedCalendarsKey)
        let snapshot = await withLiveCalendars([travel, work]) { await enricher.calendarSelectionSnapshot() }
        #expect(snapshot.scope == .noneAvailable)
        #expect(snapshot.entries.isEmpty)
        let selection = CalendarSelectionView.initialSelection(from: snapshot)
        #expect(selection == Set<String>())
        #expect(CalendarSelectionView.selectionState(selection: selection, live: live) == .noneAvailable)
        #expect(!CalendarSelectionView.isIncluded("A", in: selection))
        #expect(!CalendarSelectionView.isIncluded("B", in: selection))

        // Checking A selects A (the all-selection toggle would have kept B).
        let next = CalendarSelectionView.toggled(selection: selection, live: live, id: "A")
        #expect(next == ["A"])
        let entries = CalendarSelectionView.save(next, choices: [travel, work], previous: snapshot.entries, in: defaults)
        #expect(entries == [Entry(id: "A", accountTitle: "Google", title: "Travel")])
        #expect(CalendarEnricher.storedSelection(in: defaults) == .explicit(entries))
        #expect(defaults.stringArray(forKey: CalendarEnricher.selectedCalendarIDsKey) == ["A"])
        #expect(!defaults.bool(forKey: CalendarEnricher.selectionUnavailableKey))

        let reopened = await withLiveCalendars([travel, work]) { await enricher.calendarSelectionSnapshot() }
        #expect(reopened.scope == .calendars(["A"]))
        #expect(CalendarSelectionView.initialSelection(from: reopened) == Set(["A"]))
    }
}
