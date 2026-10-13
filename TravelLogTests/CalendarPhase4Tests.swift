//
//  CalendarPhase4Tests.swift
//  TravelLogTests
//
//  Phase 4 of the calendar integration: the Stage-2 classification prompt's
//  CALENDAR hint and the delete-calendar-data sweep.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite(.serialized, IsolatedCalendarDefaults())
struct CalendarPhase4Tests {

    private func makeStay(_ context: ModelContext, locality: String, imported: Bool) -> Stay {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let stay = Stay(startTime: start, endTime: start.addingTimeInterval(7200),
                        centroidLatitude: 0, centroidLongitude: 0,
                        h3IndexRes6: "h", pingCount: 1,
                        distanceFromHomeKm: 500, pingIDs: [])
        stay.locality = locality
        stay.sourceRaw = imported ? DataSource.photoImport.rawValue : DataSource.liveSLC.rawValue
        context.insert(stay)
        return stay
    }

    // MARK: - Classification prompt hint

    @Test func classificationPromptRendersCalendarHint() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)
        let stay = makeStay(context, locality: "Lisbon", imported: true)
        let other = makeStay(context, locality: "Porto", imported: true)

        let prompt = await classifier.buildPrompt(
            stays: [stay, other],
            calendarHints: [stay.id: "Sarah's Wedding"]
        )
        #expect(prompt.contains("CALENDAR: \"Sarah's Wedding\""))
        // Only the hinted stay's line carries the tag.
        #expect(prompt.ranges(of: "CALENDAR:").count == 1)
    }

    @Test func classificationPromptUnchangedWithoutHints() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)
        let stay = makeStay(context, locality: "Lisbon", imported: true)

        let withEmpty = await classifier.buildPrompt(stays: [stay], calendarHints: [:])
        let defaulted = await classifier.buildPrompt(stays: [stay])
        #expect(withEmpty == defaulted)
        #expect(!withEmpty.contains("CALENDAR:"))
    }

    // MARK: - Delete calendar data

    @Test func deleteAllCalendarDataWipesRowsAndPreferences() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        let context = ModelContext(container)

        for i in 0..<3 {
            let row = PlannedTrip(
                eventExternalIdentifier: "ext-\(i)", eventLocalIdentifier: "loc-\(i)",
                title: "Trip \(i)",
                startDate: .now, endDate: .now.addingTimeInterval(86_400),
                isAllDay: false, locationText: nil
            )
            context.insert(row)
        }
        try context.save()
        IsolatedCalendarDefaults.current.set(true, forKey: CalendarEnricher.thinHistoryProbeCompletedKey)
        IsolatedCalendarDefaults.current.set("Gmail", forKey: CalendarEnricher.thinHistoryAccountKey)
        IsolatedCalendarDefaults.current.set(["cal-1"], forKey: CalendarEnricher.selectedCalendarIDsKey)

        let result = await enricher.deleteAllCalendarData()

        #expect(result == CalendarEnricher.CalendarDataDeletionResult(
            succeeded: true,
            deletedCount: 3))
        #expect(try context.fetch(FetchDescriptor<PlannedTrip>()).isEmpty)
        #expect(!IsolatedCalendarDefaults.current.bool(forKey: CalendarEnricher.thinHistoryProbeCompletedKey))
        #expect(IsolatedCalendarDefaults.current.string(forKey: CalendarEnricher.thinHistoryAccountKey) == nil)
        #expect(IsolatedCalendarDefaults.current.stringArray(
            forKey: CalendarEnricher.selectedCalendarIDsKey) == ["cal-1"],
                "deletion must not widen the next scan to every calendar")
    }

    @Test func deleteAllCalendarDataRollsBackBeforeClearingPreferences() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        let context = ModelContext(container)
        let row = PlannedTrip(
            eventExternalIdentifier: "ext-failure",
            eventLocalIdentifier: "loc-failure",
            title: "Keep Me",
            startDate: .now,
            endDate: .now.addingTimeInterval(86_400),
            isAllDay: false,
            locationText: nil)
        context.insert(row)
        try context.save()
        IsolatedCalendarDefaults.current.set(
            true,
            forKey: CalendarEnricher.thinHistoryProbeCompletedKey)
        IsolatedCalendarDefaults.current.set(
            ["cal-keep"],
            forKey: CalendarEnricher.selectedCalendarIDsKey)
        defer {
            IsolatedCalendarDefaults.current.removeObject(
                forKey: CalendarEnricher.thinHistoryProbeCompletedKey)
            IsolatedCalendarDefaults.current.removeObject(
                forKey: CalendarEnricher.selectedCalendarIDsKey)
        }

        await enricher.failNextCalendarDataDelete()
        let result = await enricher.deleteAllCalendarData()

        #expect(result == CalendarEnricher.CalendarDataDeletionResult(
            succeeded: false,
            deletedCount: 0))
        #expect(try context.fetchCount(FetchDescriptor<PlannedTrip>()) == 1)
        #expect(IsolatedCalendarDefaults.current.bool(
            forKey: CalendarEnricher.thinHistoryProbeCompletedKey))
        #expect(IsolatedCalendarDefaults.current.stringArray(
            forKey: CalendarEnricher.selectedCalendarIDsKey) == ["cal-keep"])
    }

    // MARK: - Backfill guards (no Calendar grant in the test host)

    // Denied-access no-op behavior is not unit-testable without an injected
    // EventKit seam: "no access" and "no work" both return zero.
}
