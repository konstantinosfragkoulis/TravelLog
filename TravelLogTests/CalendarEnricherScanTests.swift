//
//  CalendarEnricherScanTests.swift
//  TravelLogTests
//
//  Drives `CalendarEnricher.applyScan` — the store-reconciliation half of
//  the future-lane scan — with synthetic detections over an isolated
//  test container. The EventKit half (`eventsOverlapping`, the change observer)
//  is device-verification territory, per this project's standing split.
//  Also covers the thin-history verdict and the delete-calendar-data sweep.
//

import EventKit
import Foundation
import SwiftData
import Testing
@testable import TravelLog

// `.serialized`: the two FM-cache tests share the real
// `UserDefaults.standard` key (one asserts nil, the other persists an empty
// blob) — parallel scheduling races them (StatsSnapshotStoreTests precedent).
@MainActor
@Suite(.serialized, IsolatedCalendarDefaults())
struct CalendarEnricherScanTests {

    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    // MARK: - FM judgment cache clearing

    @Test("clearFMJudgmentCache purges the persisted verdict blob (calendar PII)")
    func clearFMJudgmentCachePurgesDefaults() async throws {
        // Seed a raw blob under the real key — the cache keys embed event
        // titles/location text, which is exactly what must not survive a
        // wipe. Pre-fix, Delete All Data had NO path that removed this key
        // (only Delete Calendar Data did).
        let seeded = Data(#"{"Trip to Cephalonia|Cephalonia Port|1|0|0":{"isTrip":true}}"#.utf8)
        IsolatedCalendarDefaults.current.set(seeded, forKey: CalendarEnricher.fmJudgmentCacheKey)
        defer { IsolatedCalendarDefaults.current.removeObject(forKey: CalendarEnricher.fmJudgmentCacheKey) }

        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        await enricher.clearFMJudgmentCache()

        #expect(IsolatedCalendarDefaults.current.data(forKey: CalendarEnricher.fmJudgmentCacheKey) == nil)
    }

    @Test("clearFMJudgmentCache also empties the in-memory actor copy — no re-persist resurrection")
    func clearFMJudgmentCachePurgesActorCopy() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        defer { IsolatedCalendarDefaults.current.removeObject(forKey: CalendarEnricher.fmJudgmentCacheKey) }

        // Seed ONLY the actor-state half (storeJudgment does not persist),
        // with a far-future event end so the persist step's age prune cannot
        // mask a regression. Pre-fix — a wipe that removed only the defaults
        // key — the next scan's persist wrote this entry straight back,
        // resurrecting the event-title PII the wipe promised was gone.
        await enricher.seedJudgmentCacheForTesting(
            key: "SECRET-EVENT-TITLE|Cephalonia Port|1|0|0", isTrip: true,
            eventEndDate: Date.now.addingTimeInterval(30 * 24 * 3600)
        )
        await enricher.clearFMJudgmentCache()
        await enricher.persistJudgmentCacheForTesting()

        let data = IsolatedCalendarDefaults.current.data(forKey: CalendarEnricher.fmJudgmentCacheKey)
        let text = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        #expect(!text.contains("SECRET-EVENT-TITLE"))
    }

    private func snapshot(
        title: String,
        start: Date,
        durationHours: Double = 48,
        isAllDay: Bool = false,
        localIdentifier: String = "local-1",
        externalIdentifier: String? = "ext-1",
        recurring: Bool = false
    ) -> CalendarEventSnapshot {
        CalendarEventSnapshot(
            externalIdentifier: externalIdentifier,
            localIdentifier: localIdentifier,
            title: title,
            notes: nil,
            locationText: nil,
            startDate: start,
            endDate: start.addingTimeInterval(durationHours * 3600),
            isAllDay: isAllDay,
            hasRecurrenceRules: recurring,
            isDetached: false,
            calendarTitle: "Test",
            calendarKind: .icloud
        )
    }

    private func detection(
        _ snapshot: CalendarEventSnapshot,
        confidence: PlannedTripConfidence = .high,
        signals: [String] = ["bookingTitle"]
    ) -> PlannedTripDetection {
        PlannedTripDetection(snapshot: snapshot, confidence: confidence, signals: signals)
    }

    private func fetchAll(_ container: ModelContainer) throws -> [PlannedTrip] {
        try ModelContext(container).fetch(FetchDescriptor<PlannedTrip>())
    }

    @Test("a pre-wipe scan epoch cannot recreate PlannedTrip rows")
    func staleScanEpochIsRejectedAfterWipe() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        let staleEpoch = await enricher.calendarDataEpochForTesting()
        let result = await enricher.deleteAllCalendarData()
        #expect(result.succeeded)

        let future = now.addingTimeInterval(30 * 24 * 3600)
        await enricher.applyScan(
            detections: [detection(snapshot(
                title: "Secret Trip", start: future))],
            now: now,
            expectedEpoch: staleEpoch)

        #expect(try fetchAll(container).isEmpty)
        #expect(await enricher.calendarDataEpochForTesting()
            == staleEpoch &+ 1)
    }

    // MARK: - Upsert

    @Test func insertsNewDetections() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)

        let future = now.addingTimeInterval(30 * 24 * 3600)
        await enricher.applyScan(
            detections: [detection(snapshot(title: "Trip to Rome", start: future))],
            now: now
        )

        let rows = try fetchAll(container)
        #expect(rows.count == 1)
        #expect(rows.first?.title == "Trip to Rome")
        #expect(rows.first?.status == .upcoming)
        #expect(rows.first?.confidence == .high)
        #expect(rows.first?.signals == ["bookingTitle"])
    }

    @Test func updatesExistingRowInsteadOfDuplicating() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        let future = now.addingTimeInterval(30 * 24 * 3600)

        await enricher.applyScan(
            detections: [detection(snapshot(title: "Trip to Rome", start: future))],
            now: now
        )
        // Same identity (external id + startDate), edited title, later scan.
        // 13 h later — past `lastSeenRefreshSeconds` (12 h), so the scan
        // also refreshes `lastSeenAt`.
        let secondScan = now.addingTimeInterval(13 * 3600)
        await enricher.applyScan(
            detections: [detection(snapshot(title: "Trip to Rome & Florence", start: future), confidence: .medium)],
            now: secondScan
        )

        let rows = try fetchAll(container)
        #expect(rows.count == 1)
        #expect(rows.first?.title == "Trip to Rome & Florence")
        #expect(rows.first?.confidence == .medium)
        #expect(rows.first?.lastSeenAt == secondScan)

        // A re-scan within the refresh window leaves `lastSeenAt` alone —
        // per-scan precision would force a save (and a CloudKit export)
        // on every foreground while any detection exists, and the stale
        // sweep only needs day-level resolution.
        await enricher.applyScan(
            detections: [detection(snapshot(title: "Trip to Rome & Florence", start: future), confidence: .medium)],
            now: secondScan.addingTimeInterval(3600)
        )
        let rowsAfter = try fetchAll(container)
        #expect(rowsAfter.first?.lastSeenAt == secondScan)
    }

    @Test func allDayEndOnlyEditPersistsAndPreventsPrematureExpiry() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        let timeZone = try #require(TimeZone(secondsFromGMT: 0))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 1)))
        let extendedEnd = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 8)))
        let firstScan = start.addingTimeInterval(-24 * 3600)
        let original = snapshot(title: "Trip to Rome", start: start, isAllDay: true)
        let extended = snapshot(title: "Trip to Rome", start: start, durationHours: 7 * 24, isAllDay: true)

        await enricher.applyScan(detections: [detection(original)], now: firstScan, timeZone: timeZone)
        let originalID = try #require(try fetchAll(container).first?.id)
        await enricher.applyScan(detections: [detection(extended)], now: firstScan, timeZone: timeZone)

        // A fresh context proves the edited end was saved, not just registered.
        let rows = try fetchAll(container)
        #expect(rows.count == 1)
        #expect(rows.first?.id == originalID)
        #expect(rows.first?.startDate == start)
        #expect(rows.first?.endDate == extendedEnd)

        // The event is still live after the obsolete end's expiry grace.
        let later = original.endDate.addingTimeInterval(CalendarEnricher.expiryGraceSeconds + 3600)
        #expect(later < extendedEnd)
        await enricher.applyScan(detections: [detection(extended)], now: later, timeZone: timeZone)
        #expect(try fetchAll(container).first?.status == .upcoming)
    }

    @Test func currentAllDayExtensionRecoversExpiredRowButNotDismissedRow() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        let zone = try #require(TimeZone(secondsFromGMT: 0))
        let start = Date(timeIntervalSinceReferenceDate: 850_003_200)
        let original = snapshot(title: "Trip to Rome", start: start, isAllDay: true)
        await enricher.applyScan(detections: [detection(original)], now: start, timeZone: zone)
        let context = ModelContext(container)
        let row = try #require(context.fetch(FetchDescriptor<PlannedTrip>()).first)
        row.status = .expired
        try context.save()
        let extended = snapshot(title: "Trip to Rome", start: start, durationHours: 7 * 24, isAllDay: true)
        await enricher.applyScan(detections: [detection(extended)], now: start.addingTimeInterval(3 * 86400), timeZone: zone)
        #expect(try fetchAll(container).first?.status == .upcoming)
        let fresh = ModelContext(container)
        let dismissed = try #require(fresh.fetch(FetchDescriptor<PlannedTrip>()).first)
        dismissed.status = .dismissed
        try fresh.save()
        let longer = snapshot(title: "Trip to Rome", start: start, durationHours: 8 * 24, isAllDay: true)
        await enricher.applyScan(detections: [detection(longer)], now: start.addingTimeInterval(3 * 86400), timeZone: zone)
        #expect(try fetchAll(container).first?.status == .dismissed)
    }

    @Test("forecast publication is conditional on the exact destination, interval and physical row",
          arguments: ["unchanged", "destination", "end", "cleared", "twin"])
    func staleForecastCannotOverwriteEditedEvent(change: String) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let start = Date(timeIntervalSinceReferenceDate: 850_000_000)
        let row = PlannedTrip(eventExternalIdentifier: "forecast", eventLocalIdentifier: "forecast",
            title: "Trip to Rome", startDate: start, endDate: start.addingTimeInterval(86400),
            isAllDay: false, locationText: "Rome")
        row.resolvedLatitude = 41.9
        row.resolvedLongitude = 12.5
        context.insert(row)
        try context.save()
        let request = CalendarEnricher.ForecastRequest(id: row.id, identifier: row.persistentModelID,
            latitude: 41.9, longitude: 12.5, startDate: row.startDate, endDate: row.endDate)
        if change == "destination" { row.resolvedLatitude = 35.7 }
        if change == "end" { row.endDate = row.endDate.addingTimeInterval(86400) }
        if change == "cleared" { row.resolvedLatitude = nil; row.resolvedLongitude = nil }
        if change == "twin" {
            let twin = PlannedTrip(eventExternalIdentifier: "forecast", eventLocalIdentifier: "forecast",
                title: row.title, startDate: row.startDate, endDate: row.endDate,
                isAllDay: false, locationText: "Rome")
            twin.id = row.id
            twin.resolvedLatitude = 41.9
            twin.resolvedLongitude = 12.5
            context.delete(row)
            context.insert(twin)
        }
        try context.save()
        let enricher = CalendarEnricher(modelContainer: container)
        let epoch = await enricher.calendarDataEpochForTesting()
        let forecast = PlannedTripForecast(fetchedAt: start, days: [])
        await enricher.applyForecastForTesting(forecast, request: request, epoch: epoch)
        let saved = try #require(try fetchAll(container).first)
        #expect((saved.forecast != nil) == (change == "unchanged"))
    }

    @Test func allDaySameRenderedDaysKeepStoredInstants() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        let timeZone = try #require(TimeZone(secondsFromGMT: 0))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 1)))
        let scanDate = start.addingTimeInterval(-24 * 3600)
        let original = snapshot(title: "Trip to Rome", start: start, isAllDay: true)
        // Simulate a one-hour zone shift whose instants still render on the
        // same start and exclusive-end days in the reconciling device's zone.
        let shifted = snapshot(title: "Trip to Rome", start: start.addingTimeInterval(3600), isAllDay: true)

        await enricher.applyScan(detections: [detection(original)], now: scanDate, timeZone: timeZone)
        await enricher.applyScan(detections: [detection(shifted)], now: scanDate, timeZone: timeZone)

        let rows = try fetchAll(container)
        #expect(rows.count == 1)
        #expect(rows.first?.startDate == original.startDate)
        #expect(rows.first?.endDate == original.endDate)
        #expect(rows.first?.lastSeenAt == scanDate)
    }

    @Test func allDayRowWrittenEastIsReusedAfterMovingWest() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        let athens = try #require(TimeZone(identifier: "Europe/Athens"))
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        func midnight(_ zone: TimeZone) throws -> Date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            return try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 5)))
        }
        let athensStart = try midnight(athens)
        let newYorkStart = try midnight(newYork)
        let scanDate = athensStart.addingTimeInterval(-10 * 24 * 3600)
        let written = snapshot(title: "Trip to Rome", start: athensStart, durationHours: 4 * 24, isAllDay: true)
        let readWest = snapshot(title: "Trip to Rome", start: newYorkStart, durationHours: 4 * 24, isAllDay: true)

        await enricher.applyScan(detections: [detection(written)], now: scanDate, timeZone: athens)
        let context = ModelContext(container)
        let row = try #require(context.fetch(FetchDescriptor<PlannedTrip>()).first)
        row.status = .dismissed
        try context.save()

        // Athens midnight renders on the PREVIOUS day in New York, so the
        // stored row's key misses the snapshot's; it must still be reused.
        await enricher.applyScan(detections: [detection(readWest)], now: scanDate, timeZone: newYork)
        let rows = try fetchAll(container)
        #expect(rows.count == 1)
        #expect(rows.first?.status == .dismissed)
        #expect(rows.first?.startDate == readWest.startDate)
        #expect(rows.first?.endDate == readWest.endDate)

        await enricher.applyScan(
            detections: [detection(readWest)], now: scanDate.addingTimeInterval(4 * 24 * 3600), timeZone: newYork)
        #expect(try fetchAll(container).count == 1)
    }

    @Test func allDayRowWrittenEastIsSharedBySameKeySnapshotsAfterMovingWest() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        let athens = try #require(TimeZone(identifier: "Europe/Athens"))
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        func midnight(_ zone: TimeZone) throws -> Date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            return try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 5)))
        }
        let scanDate = try midnight(athens).addingTimeInterval(-10 * 24 * 3600)
        let written = snapshot(title: "Trip to Rome", start: try midnight(athens), durationHours: 4 * 24, isAllDay: true)

        await enricher.applyScan(detections: [detection(written)], now: scanDate, timeZone: athens)
        let context = ModelContext(container)
        let row = try #require(context.fetch(FetchDescriptor<PlannedTrip>()).first)
        row.status = .dismissed
        try context.save()

        // The same invite in two calendars: one external ID, two local IDs.
        let newYorkStart = try midnight(newYork)
        let detections = ["local-1", "local-2"].map {
            detection(snapshot(
                title: "Trip to Rome", start: newYorkStart, durationHours: 4 * 24, isAllDay: true, localIdentifier: $0))
        }
        await enricher.applyScan(detections: detections, now: scanDate, timeZone: newYork)
        let rows = try fetchAll(container)
        #expect(rows.count == 1)
        #expect(rows.first?.status == .dismissed)
    }

    @Test func allDayAdjacentInstancesStayDistinctWithFallback() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        let athens = try #require(TimeZone(identifier: "Europe/Athens"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = athens
        let first = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 5)))
        let second = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 6)))
        let scanDate = first.addingTimeInterval(-10 * 24 * 3600)
        let detections = [
            detection(snapshot(title: "Ski trip", start: first, durationHours: 24, isAllDay: true)),
            detection(snapshot(title: "Ski trip", start: second, durationHours: 24, isAllDay: true)),
        ]

        await enricher.applyScan(detections: detections, now: scanDate, timeZone: athens)
        await enricher.applyScan(detections: detections.reversed(), now: scanDate, timeZone: athens)

        let rows = try fetchAll(container)
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.startDate)) == [first, second])
    }

    @Test func allDayRowWrittenWestKeepsInstantsWhenReadEast() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        let athens = try #require(TimeZone(identifier: "Europe/Athens"))
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        func midnight(_ zone: TimeZone) throws -> Date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            return try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 5)))
        }
        let newYorkStart = try midnight(newYork)
        let scanDate = newYorkStart.addingTimeInterval(-10 * 24 * 3600)
        let written = snapshot(title: "Trip to Rome", start: newYorkStart, durationHours: 4 * 24, isAllDay: true)
        let readEast = snapshot(title: "Trip to Rome", start: try midnight(athens), durationHours: 4 * 24, isAllDay: true)

        await enricher.applyScan(detections: [detection(written)], now: scanDate, timeZone: newYork)
        await enricher.applyScan(detections: [detection(readEast)], now: scanDate, timeZone: athens)

        let rows = try fetchAll(container)
        #expect(rows.count == 1)
        #expect(rows.first?.startDate == written.startDate)
        #expect(rows.first?.endDate == written.endDate)
    }

    /// "writer>reader": the zone the stored rows were rendered in, then the
    /// zone the next scan runs in.
    private static func zones(_ pair: String) throws -> (writer: TimeZone, reader: TimeZone) {
        let names = pair.split(separator: ">").map(String.init)
        return (try #require(TimeZone(identifier: names[0])), try #require(TimeZone(identifier: names[1])))
    }

    private func allDayStart(day: Int, in zone: TimeZone) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: day)))
    }

    @Test("a new all-day occurrence keeps the previous and next day's rows",
          arguments: [
              "Europe/Athens>Europe/Athens", "America/New_York>America/New_York",
              "Pacific/Honolulu>Pacific/Honolulu", "Pacific/Auckland>Pacific/Auckland",
              "Pacific/Kiritimati>Pacific/Kiritimati", "Europe/London>Europe/Athens",
              "America/New_York>Europe/London",
              // Honolulu's November 5 midnight is also November 6's at
              // UTC+14 and Pago Pago's at UTC+13; Fiji's November 7 would be
              // November 6's only at UTC-12, which no place uses.
              "Pacific/Honolulu>America/New_York", "Pacific/Pago_Pago>Europe/London",
              "Pacific/Fiji>Pacific/Kiritimati",
          ], [PlannedTripStatus.dismissed, .matched, .upcoming])
    func allDayNewOccurrenceKeepsAdjacentDayRows(pair: String, status: PlannedTripStatus) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        let (writer, reader) = try Self.zones(pair)
        let previous = snapshot(
            title: "Vacation", start: try allDayStart(day: 5, in: writer), durationHours: 24, isAllDay: true, recurring: true)
        let next = snapshot(
            title: "Vacation", start: try allDayStart(day: 7, in: writer), durationHours: 24, isAllDay: true, recurring: true)
        await enricher.applyScan(
            detections: [detection(previous), detection(next)],
            now: previous.startDate.addingTimeInterval(-12 * 3600), timeZone: writer)
        let context = ModelContext(container)
        let stored = try context.fetch(FetchDescriptor<PlannedTrip>())
        var matchedTripIDs: [UUID: UUID] = [:]
        for row in stored {
            row.status = status
            if status == .matched {
                row.matchedTripID = UUID()
                matchedTripIDs[row.id] = row.matchedTripID
            }
        }
        try context.save()

        // The series gains November 6 after November 5 has ended, so the scan
        // holds only the new occurrence and no row carries its exact key.
        let current = snapshot(
            title: "Vacation", start: try allDayStart(day: 6, in: reader), durationHours: 24, isAllDay: true, recurring: true)
        await enricher.applyScan(
            detections: [detection(current)], now: current.startDate.addingTimeInterval(3600), timeZone: reader)

        let rows = try fetchAll(container)
        #expect(rows.count == 3)
        for original in [previous, next] {
            let row = try #require(rows.first { $0.startDate == original.startDate })
            #expect(row.endDate == original.endDate)
            #expect(row.status == status)
            #expect(row.matchedTripID == matchedTripIDs[row.id])
        }
        let added = try #require(rows.first { $0.startDate == current.startDate })
        #expect(!stored.map(\.id).contains(added.id))
        #expect(added.status == .upcoming)
        #expect(added.matchedTripID == nil)
    }

    @Test func allDayDetachedOccurrenceKeepsPreviousDayRow() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        let (honolulu, newYork) = try Self.zones("Pacific/Honolulu>America/New_York")
        let previous = snapshot(
            title: "Vacation", start: try allDayStart(day: 5, in: honolulu), durationHours: 24, isAllDay: true, recurring: true)
        await enricher.applyScan(
            detections: [detection(previous)], now: previous.startDate.addingTimeInterval(-12 * 3600), timeZone: honolulu)
        let context = ModelContext(container)
        let row = try #require(context.fetch(FetchDescriptor<PlannedTrip>()).first)
        row.status = .dismissed
        try context.save()

        // An occurrence the user edited on its own; it may not report rules.
        let edited = CalendarEventSnapshot(
            externalIdentifier: "ext-1", localIdentifier: "local-1", title: "Vacation", notes: nil, locationText: nil,
            startDate: try allDayStart(day: 6, in: newYork), endDate: try allDayStart(day: 7, in: newYork), isAllDay: true,
            hasRecurrenceRules: false, isDetached: true, calendarTitle: "Test", calendarKind: .icloud)
        await enricher.applyScan(
            detections: [detection(edited)], now: edited.startDate.addingTimeInterval(3600), timeZone: newYork)

        let rows = try fetchAll(container)
        #expect(rows.count == 2)
        let kept = try #require(rows.first { $0.id == row.id })
        #expect(kept.startDate == previous.startDate)
        #expect(kept.status == .dismissed)
        #expect(rows.first { $0.id != row.id }?.status == .upcoming)
    }

    @Test("an all-day row written further east is adopted when it can be the same date",
          arguments: [
              "Pacific/Auckland>America/New_York", "Pacific/Kiritimati>Europe/London",
              "Asia/Tokyo>America/Los_Angeles", "Pacific/Auckland>Pacific/Honolulu",
          ])
    func allDayRowWrittenFurtherEastIsAdopted(pair: String) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        let (writer, reader) = try Self.zones(pair)
        let written = snapshot(title: "Trip to Rome", start: try allDayStart(day: 5, in: writer), durationHours: 4 * 24, isAllDay: true)
        let read = snapshot(title: "Trip to Rome", start: try allDayStart(day: 5, in: reader), durationHours: 4 * 24, isAllDay: true)
        let scanDate = written.startDate.addingTimeInterval(-10 * 24 * 3600)
        await enricher.applyScan(detections: [detection(written)], now: scanDate, timeZone: writer)
        let context = ModelContext(container)
        let row = try #require(context.fetch(FetchDescriptor<PlannedTrip>()).first)
        row.status = .dismissed
        try context.save()

        await enricher.applyScan(detections: [detection(read)], now: scanDate, timeZone: reader)

        let rows = try fetchAll(container)
        #expect(rows.count == 1)
        #expect(rows.first?.id == row.id)
        #expect(rows.first?.status == .dismissed)
        #expect(rows.first?.startDate == read.startDate)
        #expect(rows.first?.endDate == read.endDate)
    }

    /// An all-day event as EventKit returns it: the zone's midnight on
    /// November `day`, ending at 23:59:59 of its last day in that zone
    /// rather than at the next midnight.
    private func eventKitAllDay(day: Int, days: Int, in zone: TimeZone, recurring: Bool = false) throws -> CalendarEventSnapshot {
        CalendarEventSnapshot(
            externalIdentifier: "ext-1", localIdentifier: "local-1", title: "Trip to Rome", notes: nil, locationText: nil,
            startDate: try allDayStart(day: day, in: zone),
            endDate: try allDayStart(day: day + days, in: zone).addingTimeInterval(-1), isAllDay: true,
            hasRecurrenceRules: recurring, isDetached: false, calendarTitle: "Test", calendarKind: .icloud)
    }

    /// Zone pairs within 24 h of each other, single and recurring. A row
    /// written at UTC+13 is also the previous day's midnight at UTC-11, so
    /// a recurring occurrence never adopts it: Auckland>Honolulu is single only.
    @Test("two devices in different zones settle on one all-day row",
          arguments: [
              ("Europe/Athens>America/New_York", false), ("Europe/Athens>America/New_York", true),
              ("America/New_York>Europe/Athens", false), ("America/New_York>Europe/Athens", true),
              ("Asia/Tokyo>America/Los_Angeles", false), ("Asia/Tokyo>America/Los_Angeles", true),
              ("Europe/Paris>Europe/London", false), ("Europe/Paris>Europe/London", true),
              ("Pacific/Honolulu>Pacific/Auckland", false), ("Pacific/Honolulu>Pacific/Auckland", true),
              ("Pacific/Auckland>Pacific/Honolulu", false),
          ])
    func allDayRowSettlesAcrossTwoDevices(pair: String, recurring: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        let (writer, reader) = try Self.zones(pair)
        let written = try eventKitAllDay(day: 5, days: 4, in: writer, recurring: recurring)
        let read = try eventKitAllDay(day: 5, days: 4, in: reader, recurring: recurring)
        let scanDate = written.startDate.addingTimeInterval(-10 * 24 * 3600)
        func scan(_ snapshot: CalendarEventSnapshot, in zone: TimeZone) async {
            await enricher.applyScan(detections: [detection(snapshot)], now: scanDate, timeZone: zone)
        }

        await scan(written, in: writer)
        let context = ModelContext(container)
        let row = try #require(context.fetch(FetchDescriptor<PlannedTrip>()).first)
        row.status = .dismissed
        try context.save()
        await scan(read, in: reader)
        await scan(written, in: writer)
        await scan(read, in: reader)
        let settled = try #require(try fetchAll(container).first)
        let (start, end, lastSeenAt) = (settled.startDate, settled.endDate, settled.lastSeenAt)

        // Each device's own scan now finds nothing to rewrite.
        await scan(written, in: writer)
        await scan(read, in: reader)

        let rows = try fetchAll(container)
        #expect(rows.count == 1)
        let kept = try #require(rows.first)
        #expect(kept.id == row.id)
        #expect(kept.status == .dismissed)
        #expect(kept.startDate == start)
        #expect(kept.endDate == end)
        #expect(kept.lastSeenAt == lastSeenAt)
        for (zone, snapshot) in [(writer, written), (reader, read)] {
            #expect(PlannedTripDetector.renderedDayKey(kept.startDate, timeZone: zone)
                == PlannedTripDetector.renderedDayKey(snapshot.startDate, timeZone: zone), "\(zone.identifier)")
            #expect(PlannedTripDetector.renderedDayKey(kept.endDate, timeZone: zone)
                == PlannedTripDetector.renderedDayKey(snapshot.endDate, timeZone: zone), "\(zone.identifier)")
        }
    }

    @Test func allDayDateChangesStillPropagateAcrossSettledDevices() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        let athens = try #require(TimeZone(identifier: "Europe/Athens"))
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        let scanDate = try allDayStart(day: 5, in: athens).addingTimeInterval(-10 * 24 * 3600)
        func scan(day: Int, days: Int, in zone: TimeZone) async throws {
            let snapshot = try eventKitAllDay(day: day, days: days, in: zone)
            await enricher.applyScan(detections: [detection(snapshot)], now: scanDate, timeZone: zone)
        }
        // The rows whose days render as `day` for `days` days in both zones.
        func rows(day: Int, days: Int) throws -> [PlannedTrip] {
            var expected: [(zone: TimeZone, start: String, end: String)] = []
            for zone in [athens, newYork] {
                let snapshot = try eventKitAllDay(day: day, days: days, in: zone)
                expected.append((zone, PlannedTripDetector.renderedDayKey(snapshot.startDate, timeZone: zone),
                                 PlannedTripDetector.renderedDayKey(snapshot.endDate, timeZone: zone)))
            }
            return try fetchAll(container).filter { row in
                expected.allSatisfy {
                    PlannedTripDetector.renderedDayKey(row.startDate, timeZone: $0.zone) == $0.start
                        && PlannedTripDetector.renderedDayKey(row.endDate, timeZone: $0.zone) == $0.end
                }
            }
        }

        for zone in [athens, newYork, athens, newYork] { try await scan(day: 5, days: 4, in: zone) }
        let settled = try #require(try rows(day: 5, days: 4).first)
        let (settledID, settledStart) = (settled.id, settled.startDate)

        // Extending the event by two days reaches both zones' end days
        // without disturbing the settled start.
        for zone in [newYork, athens, newYork, athens] { try await scan(day: 5, days: 6, in: zone) }
        #expect(try fetchAll(container).count == 1)
        let extended = try #require(try rows(day: 5, days: 6).first)
        #expect(extended.id == settledID)
        #expect(extended.startDate == settledStart)
        let extendedEnd = extended.endDate
        for zone in [newYork, athens] { try await scan(day: 5, days: 6, in: zone) }
        let again = try #require(try rows(day: 5, days: 6).first)
        #expect(again.startDate == settledStart)
        #expect(again.endDate == extendedEnd)

        // Moving it a day later gives exactly one row on the new days in
        // both zones, which then stays put.
        for zone in [athens, newYork, athens, newYork] { try await scan(day: 6, days: 6, in: zone) }
        let moved = try rows(day: 6, days: 6)
        #expect(moved.count == 1)
        let movedRow = try #require(moved.first)
        let (movedID, movedStart, movedEnd) = (movedRow.id, movedRow.startDate, movedRow.endDate)
        for zone in [athens, newYork] { try await scan(day: 6, days: 6, in: zone) }
        let stable = try rows(day: 6, days: 6)
        #expect(stable.count == 1)
        #expect(stable.first?.id == movedID)
        #expect(stable.first?.startDate == movedStart)
        #expect(stable.first?.endDate == movedEnd)
    }

    @Test("a row counts as current until the end of the day its end renders on, never earlier than that end")
    func currentUntilFollowsRenderedLastDay() throws {
        let athens = try #require(TimeZone(identifier: "Europe/Athens"))
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        func row(_ snapshot: CalendarEventSnapshot) -> PlannedTrip {
            PlannedTrip(eventExternalIdentifier: snapshot.externalIdentifier, eventLocalIdentifier: snapshot.localIdentifier,
                        title: snapshot.title, startDate: snapshot.startDate, endDate: snapshot.endDate,
                        isAllDay: snapshot.isAllDay, locationText: nil)
        }

        // A timed row ends at its end, wherever it is read.
        let timed = row(snapshot(title: "Flight", start: try allDayStart(day: 5, in: athens), durationHours: 3))
        #expect(timed.currentUntil(timeZone: athens) == timed.endDate)
        #expect(timed.currentUntil(timeZone: newYork) == timed.endDate)

        // An exclusive-midnight end already is the end of the last day.
        let exclusive = row(snapshot(title: "Trip to Rome", start: try allDayStart(day: 5, in: newYork),
                                     durationHours: 4 * 24, isAllDay: true))
        #expect(exclusive.currentUntil(timeZone: newYork) == exclusive.endDate)

        // A row written in one zone counts until its own last second there.
        // Read elsewhere, its start is not a local midnight, so it keeps its
        // end: New York's 23:59:59 renders on November 9 in Athens, like the
        // card there does, and must not linger through November 9 as well.
        let east = row(try eventKitAllDay(day: 5, days: 4, in: athens))
        #expect(east.currentUntil(timeZone: athens) == east.endDate.addingTimeInterval(1))
        #expect(east.currentUntil(timeZone: newYork) == east.endDate)
        let west = row(try eventKitAllDay(day: 5, days: 4, in: newYork))
        #expect(west.currentUntil(timeZone: newYork) == west.endDate.addingTimeInterval(1))
        #expect(west.currentUntil(timeZone: athens) == west.endDate)

        // Two synced devices settle on New York's midnight and Athens's last
        // second. Athens's 23:59:59 renders at 16:59:59 in New York, so the
        // row stays current there until New York's own midnight; in Athens
        // it ends at its own last second.
        let settled = PlannedTrip(eventExternalIdentifier: "ext-1", eventLocalIdentifier: "local-1",
                                  title: "Trip to Rome", startDate: try allDayStart(day: 5, in: newYork),
                                  endDate: east.endDate, isAllDay: true, locationText: nil)
        let newYorkNinth = try allDayStart(day: 9, in: newYork)
        #expect(settled.currentUntil(timeZone: newYork) == newYorkNinth)
        #expect(settled.currentUntil(timeZone: athens) == settled.endDate)
    }

    @Test func allDayRowStaysCurrentThroughItsLastLocalDayAfterAlternatingScans() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        let athens = try #require(TimeZone(identifier: "Europe/Athens"))
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        let scanDate = try allDayStart(day: 5, in: athens).addingTimeInterval(-10 * 24 * 3600)
        func scan(in zone: TimeZone, now: Date) async throws {
            let snapshot = try eventKitAllDay(day: 5, days: 4, in: zone)
            await enricher.applyScan(detections: [detection(snapshot)], now: now, timeZone: zone)
        }
        for zone in [athens, newYork, athens, newYork] { try await scan(in: zone, now: scanDate) }
        let settled = try #require(try fetchAll(container).first)
        // The row settles on New York's midnight and Athens's last second,
        // which New York renders at 16:59:59 on November 8.
        let newYorkStart = try allDayStart(day: 5, in: newYork)
        let athensEnd = try eventKitAllDay(day: 5, days: 4, in: athens).endDate
        #expect(settled.startDate == newYorkStart)
        #expect(settled.endDate == athensEnd)
        let newYorkMidnight = try allDayStart(day: 9, in: newYork)
        #expect(settled.currentUntil(timeZone: newYork) == newYorkMidnight)

        // The journey has been assembled as a real trip. On the last evening
        // in New York the row is still current: not retired, not hidden.
        let context = ModelContext(container)
        let trip = Trip(startDate: settled.startDate)
        trip.endDate = newYorkMidnight
        trip.isComplete = true
        context.insert(trip)
        try context.save()
        let lastEvening = newYorkMidnight.addingTimeInterval(-6 * 3600)
        #expect(lastEvening > settled.endDate)
        try await scan(in: newYork, now: lastEvening)
        let evening = try #require(try fetchAll(container).first)
        #expect(evening.status == .upcoming)
        #expect(evening.currentUntil(timeZone: newYork) >= lastEvening)

        // After New York's midnight it retires against the trip.
        try await scan(in: newYork, now: newYorkMidnight.addingTimeInterval(1800))
        let retired = try #require(try fetchAll(container).first)
        #expect(retired.status == .matched)
        #expect(retired.matchedTripID == trip.id)
    }

    /// Every offset a place uses is a quarter hour from UTC-11 to UTC+14.
    private static let placeOffsets = Array(-44...56).map { $0 * 900 }

    @Test("every zone's 2026 offsets are quarter hours from UTC-11 to UTC+14")
    func zoneOffsetsAreWithinPlaceOffsets() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let dates = try (1...12).map { try #require(utc.date(from: DateComponents(year: 2026, month: $0, day: 15))) }
        var outside: Set<String> = []
        for identifier in TimeZone.knownTimeZoneIdentifiers {
            let zone = try #require(TimeZone(identifier: identifier))
            for date in dates where !Self.placeOffsets.contains(zone.secondsFromGMT(for: date)) {
                outside.insert("\(identifier) \(zone.secondsFromGMT(for: date))")
            }
        }
        #expect(outside.isEmpty, "\(outside.sorted())")
    }

    @Test("at every offset pair a row can be an occurrence's own date, and a recurring one's only when it can be no other")
    func allDayFloatingDateAtEveryOffsetPair() throws {
        let day = 24 * 3600
        let floatingMidnight = try allDayStart(day: 6, in: .gmt)
        let readers = try Self.placeOffsets.map { ($0, try #require(TimeZone(secondsFromGMT: $0))) }
        var failures: [String] = []
        for writer in Self.placeOffsets {
            // The writer's November 6 midnight, and each day whose midnight
            // it is at an offset some place uses.
            let stored = floatingMidnight.addingTimeInterval(TimeInterval(-writer))
            let possibleDays = (-2...2).filter { Self.placeOffsets.contains(writer + $0 * day) }
            for (reader, zone) in readers {
                let readerMidnight = (reader - writer) % day == 0
                for shift in -2...2 {
                    let snapshotStart = floatingMidnight.addingTimeInterval(TimeInterval(shift * day - reader))
                    for recurring in [false, true] {
                        let expected = !readerMidnight && possibleDays.contains(shift)
                            && (!recurring || possibleDays == [shift])
                        let adopted = CalendarEnricher.allDayStart(
                            stored, canBeFloatingDayOf: snapshotStart, timeZone: zone, excludingAdjacentDays: recurring)
                        if adopted != expected {
                            failures.append("writer \(writer / 60) min, reader \(reader / 60) min, day \(shift), recurring \(recurring)")
                        }
                    }
                }
            }
        }
        #expect(failures.count == 0, "first: \(failures.prefix(10))")
    }

    /// Zones at both ends of the offset range and in its ambiguous hours
    /// (UTC-11 to UTC-10 and UTC+13 to UTC+14), at UTC+12 just outside them,
    /// and in between (November 2026).
    enum SweepZone: String, CaseIterable, Sendable {
        case pagoPago = "Pacific/Pago_Pago", honolulu = "Pacific/Honolulu", newYork = "America/New_York"
        case fiji = "Pacific/Fiji", auckland = "Pacific/Auckland", kiritimati = "Pacific/Kiritimati"
    }

    @Test("across zones no new occurrence takes an adjacent day's row, and a row is reused wherever it cannot be one",
          arguments: SweepZone.allCases, SweepZone.allCases)
    func allDayRowsAcrossZones(writer: SweepZone, reader: SweepZone) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        let writerZone = try #require(TimeZone(identifier: writer.rawValue))
        let readerZone = try #require(TimeZone(identifier: reader.rawValue))
        let statuses: [PlannedTripStatus] = [.dismissed, .matched, .upcoming]
        // A daily series per status with rows for November 5 and 7...
        func occurrence(day: Int, in zone: TimeZone, _ status: PlannedTripStatus) throws -> CalendarEventSnapshot {
            snapshot(title: "Vacation", start: try allDayStart(day: day, in: zone), durationHours: 24, isAllDay: true,
                     localIdentifier: "local-\(status)", externalIdentifier: "ext-\(status)", recurring: true)
        }
        // ...and a dismissed single and yearly trip from November 20.
        func trip(in zone: TimeZone, recurring: Bool) throws -> CalendarEventSnapshot {
            let event = recurring ? "yearly" : "single"
            return snapshot(title: "Trip to Rome", start: try allDayStart(day: 20, in: zone), durationHours: 4 * 24,
                            isAllDay: true, localIdentifier: "local-\(event)", externalIdentifier: "ext-\(event)",
                            recurring: recurring)
        }
        let adjacent = try statuses.flatMap { [try occurrence(day: 5, in: writerZone, $0), try occurrence(day: 7, in: writerZone, $0)] }
        let written = try [false, true].map { try trip(in: writerZone, recurring: $0) }
        await enricher.applyScan(
            detections: (adjacent + written).map { detection($0) },
            now: adjacent[0].startDate.addingTimeInterval(-12 * 3600), timeZone: writerZone)
        let context = ModelContext(container)
        let stored = try context.fetch(FetchDescriptor<PlannedTrip>())
        try #require(stored.count == adjacent.count + written.count)
        for row in stored {
            let status = statuses.first { row.eventExternalIdentifier == "ext-\($0)" } ?? .dismissed
            row.status = status
            if status == .matched { row.matchedTripID = UUID() }
        }
        try context.save()
        struct Original {
            let id: UUID, event: String?, start: Date, end: Date, status: PlannedTripStatus, matchedTripID: UUID?
        }
        let originals = stored.map {
            Original(id: $0.id, event: $0.eventExternalIdentifier, start: $0.startDate, end: $0.endDate,
                     status: $0.status, matchedTripID: $0.matchedTripID)
        }

        // Each series gains November 6 after November 5 has ended.
        let current = try statuses.map { try occurrence(day: 6, in: readerZone, $0) }
        let read = try [false, true].map { try trip(in: readerZone, recurring: $0) }
        await enricher.applyScan(
            detections: (current + read).map { detection($0) },
            now: current[0].startDate.addingTimeInterval(3600), timeZone: readerZone)

        let rows = try fetchAll(container)
        let newDay = PlannedTripDetector.renderedDayKey(current[0].startDate, timeZone: readerZone)
        for (status, snapshot) in zip(statuses, current) {
            let pair = "\(writer)>\(reader) \(status)"
            let seriesRows = rows.filter { $0.eventExternalIdentifier == snapshot.externalIdentifier }
            var exactlyNamed = false
            for original in originals where original.event == snapshot.externalIdentifier {
                // A row the reader's own day reading already names November 6
                // goes through the exact key, not the cross-zone fallback.
                if PlannedTripDetector.renderedDayKey(original.start, timeZone: readerZone) == newDay {
                    exactlyNamed = true
                    continue
                }
                let row = seriesRows.first { $0.id == original.id }
                #expect(row?.startDate == original.start, "\(pair)")
                #expect(row?.endDate == original.end, "\(pair)")
                #expect(row?.status == original.status, "\(pair)")
                #expect(row?.matchedTripID == original.matchedTripID, "\(pair)")
            }
            guard !exactlyNamed else { continue }
            #expect(seriesRows.count == 3, "\(pair)")
            let added = seriesRows.first { row in !originals.contains { $0.id == row.id } }
            #expect(added?.startDate == snapshot.startDate, "\(pair)")
            #expect(added?.status == .upcoming, "\(pair)")
            #expect(added?.matchedTripID == nil, "\(pair)")
        }

        let hour = 3600
        let writerOffset = writerZone.secondsFromGMT(for: written[0].startDate)
        let readerOffset = readerZone.secondsFromGMT(for: read[0].startDate)
        // Offsets exactly 24 h apart make the stored start a midnight of the
        // reader's own zone on another day, which reads as written there.
        let singleReused = abs(writerOffset - readerOffset) != 24 * hour
        // A recurring row either renders on its own day for this reader, or
        // is that day's midnight at no offset that could make it an adjacent
        // day's (strictly between UTC-10 and UTC+13).
        let recurringReused = (0..<24 * hour).contains(readerOffset - writerOffset)
            || (-10 * hour + 1..<13 * hour).contains(writerOffset)
        for (index, reused) in [singleReused, recurringReused].enumerated() {
            let pair = "\(writer)>\(reader) \(index == 0 ? "single" : "recurring")"
            let original = try #require(originals.first { $0.event == written[index].externalIdentifier })
            let eventRows = rows.filter { $0.eventExternalIdentifier == written[index].externalIdentifier }
            let kept = eventRows.first { $0.id == original.id }
            #expect(kept?.status == .dismissed, "\(pair)")
            if reused {
                #expect(eventRows.count == 1, "\(pair)")
                let keptStart = kept.map { PlannedTripDetector.renderedDayKey($0.startDate, timeZone: readerZone) }
                let keptEnd = kept.map { PlannedTripDetector.renderedDayKey($0.endDate, timeZone: readerZone) }
                #expect(keptStart == PlannedTripDetector.renderedDayKey(read[index].startDate, timeZone: readerZone), "\(pair)")
                #expect(keptEnd == PlannedTripDetector.renderedDayKey(read[index].endDate, timeZone: readerZone), "\(pair)")
            } else {
                #expect(eventRows.count == 2, "\(pair)")
                #expect(kept?.startDate == written[index].startDate, "\(pair)")
                #expect(kept?.endDate == written[index].endDate, "\(pair)")
                let added = eventRows.first { $0.id != original.id }
                #expect(added?.startDate == read[index].startDate, "\(pair)")
                #expect(added?.status == .upcoming, "\(pair)")
            }
        }
    }

    @Test func recurrenceInstancesCreateDistinctRows() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)

        let first = now.addingTimeInterval(10 * 24 * 3600)
        let second = now.addingTimeInterval(17 * 24 * 3600)
        // Same event identifiers — expanded occurrences of one recurring event.
        await enricher.applyScan(
            detections: [
                detection(snapshot(title: "Ski trip", start: first)),
                detection(snapshot(title: "Ski trip", start: second)),
            ],
            now: now
        )

        let rows = try fetchAll(container)
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.startDate)) == [first, second])
    }

    @Test func dismissedRowIsUpdatedButNeverResurrected() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        let future = now.addingTimeInterval(30 * 24 * 3600)
        let event = snapshot(title: "Trip to Rome", start: future)

        await enricher.applyScan(detections: [detection(event)], now: now)

        // User dismisses the card.
        let context = ModelContext(container)
        let row = try #require(try context.fetch(FetchDescriptor<PlannedTrip>()).first)
        row.status = .dismissed
        try context.save()

        // Next scan still sees the event — status must stay dismissed.
        await enricher.applyScan(detections: [detection(event)], now: now.addingTimeInterval(3600))
        let rows = try fetchAll(container)
        #expect(rows.count == 1)
        #expect(rows.first?.status == .dismissed)
    }

    // MARK: - Staleness sweep

    @Test func vanishedFutureRowIsSweptAfterGrace() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        let future = now.addingTimeInterval(30 * 24 * 3600)

        await enricher.applyScan(
            detections: [detection(snapshot(title: "Trip to Rome", start: future))],
            now: now
        )

        // Within grace: an empty scan must NOT delete it.
        let withinGrace = now.addingTimeInterval(CalendarEnricher.staleGraceSeconds - 3600)
        await enricher.applyScan(detections: [], now: withinGrace)
        #expect(try fetchAll(container).count == 1)

        // Past grace: swept.
        let pastGrace = now.addingTimeInterval(CalendarEnricher.staleGraceSeconds + 3600)
        await enricher.applyScan(detections: [], now: pastGrace)
        #expect(try fetchAll(container).isEmpty)
    }

    // MARK: - Retirement

    @Test func passedDatesWithMatchingTripRetireAsMatched() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)

        // Planned trip already in the store, dated in the past.
        let plannedStart = now.addingTimeInterval(-6 * 24 * 3600)
        await enricher.applyScan(
            detections: [detection(snapshot(title: "Trip to Rome", start: plannedStart, durationHours: 4 * 24))],
            now: plannedStart.addingTimeInterval(-24 * 3600)
        )

        // A real Trip covering those dates has since been assembled.
        let context = ModelContext(container)
        let trip = Trip(startDate: plannedStart)
        trip.endDate = plannedStart.addingTimeInterval(4 * 24 * 3600)
        trip.isComplete = true
        context.insert(trip)
        try context.save()

        await enricher.applyScan(detections: [], now: now)

        let row = try #require(try fetchAll(container).first)
        #expect(row.status == .matched)
        #expect(row.matchedTripID == trip.id)
    }

    @Test func passedDatesWithoutTripExpireOnlyAfterGrace() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)

        let plannedStart = now.addingTimeInterval(-3 * 24 * 3600)
        let plannedEnd = plannedStart.addingTimeInterval(2 * 24 * 3600)  // ended 1 day ago
        await enricher.applyScan(
            detections: [detection(snapshot(title: "Trip to Rome", start: plannedStart, durationHours: 2 * 24))],
            now: plannedStart.addingTimeInterval(-24 * 3600)
        )

        // Ended one day ago — inside the expiry grace, stays upcoming
        // (the real trip may still be assembling from pings).
        await enricher.applyScan(detections: [], now: now)
        #expect(try fetchAll(container).first?.status == .upcoming)

        // Past the grace with no trip in sight — expired.
        let later = plannedEnd.addingTimeInterval(CalendarEnricher.expiryGraceSeconds + 3600)
        await enricher.applyScan(detections: [], now: later)
        #expect(try fetchAll(container).first?.status == .expired)
    }

    @Test func matchedRowIsNeverSweptByLaterScans() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)

        let plannedStart = now.addingTimeInterval(-10 * 24 * 3600)
        await enricher.applyScan(
            detections: [detection(snapshot(title: "Trip to Rome", start: plannedStart, durationHours: 3 * 24))],
            now: plannedStart.addingTimeInterval(-24 * 3600)
        )
        let context = ModelContext(container)
        let trip = Trip(startDate: plannedStart)
        trip.endDate = plannedStart.addingTimeInterval(3 * 24 * 3600)
        trip.isComplete = true
        context.insert(trip)
        try context.save()
        await enricher.applyScan(detections: [], now: now)
        #expect(try fetchAll(container).first?.status == .matched)

        // Months later, the source calendar event is long gone from every
        // scan — the matched row is a historical record and must survive.
        await enricher.applyScan(detections: [], now: now.addingTimeInterval(90 * 24 * 3600))
        let rows = try fetchAll(container)
        #expect(rows.count == 1)
        #expect(rows.first?.status == .matched)
    }

    // MARK: - Activation scan throttle

    /// `.notDetermined` keeps the scan on the no-access exit, so no EventKit
    /// query runs.
    private func scanIfDue(_ enricher: CalendarEnricher, at date: Date) async {
        await CalendarEnricher.TestScope.$authorizationStatus.withValue(.notDetermined) {
            await enricher.scanUpcomingTripsIfDue(now: date)
        }
    }

    @Test("the activation throttle skips only a recent, unchanged, readable calendar")
    func activationThrottleRule() {
        let due = { (access: Bool, changed: Bool, ago: TimeInterval?) in
            CalendarEnricher.activationScanIsDue(
                hasReadAccess: access, storeChangedSinceScan: changed,
                lastScanCompletedAt: ago.map { now.addingTimeInterval(-$0) },
                now: now, minInterval: 30 * 60)
        }
        #expect(due(true, false, nil))          // first scan of the process
        #expect(!due(true, false, 60))
        #expect(!due(true, false, 29 * 60))
        #expect(due(true, false, 30 * 60))
        #expect(due(true, true, 60))            // calendar changed
        #expect(due(false, false, 60))          // access lost: cleanup runs
    }

    @Test("a completed pass arms the throttle; a calendar change or a revocation re-arms the scan")
    func actorStateDrivesTheThrottle() async throws {
        let enricher = CalendarEnricher(modelContainer: try TestSupport.makeInMemoryContainer())
        #expect(await enricher.activationScanIsDueForTesting(now: now))
        await enricher.recordCompletedScanForTesting(at: now)
        #expect(!(await enricher.activationScanIsDueForTesting(now: now.addingTimeInterval(60))))
        #expect(await enricher.activationScanIsDueForTesting(now: now.addingTimeInterval(30 * 60)))

        await enricher.simulateStoreChangeForTesting()
        #expect(await enricher.activationScanIsDueForTesting(now: now.addingTimeInterval(60)))

        await enricher.recordCompletedScanForTesting(at: now)
        await enricher.beginCalendarDataRevocation()
        #expect(await enricher.activationScanIsDueForTesting(now: now.addingTimeInterval(60)))
    }

    @Test("losing read access after a completed pass still runs the activation scan's cleanup")
    func accessLossBypassesThrottle() async throws {
        let enricher = CalendarEnricher(modelContainer: try TestSupport.makeInMemoryContainer())
        await enricher.recordCompletedScanForTesting(at: now)
        await scanIfDue(enricher, at: now.addingTimeInterval(60))
        #expect(await enricher.scanCountForTesting == 1)
    }
}

// MARK: - Thin history, reconcile persistence and calendar data deletion

extension CalendarEnricherScanTests {

    // MARK: - Thin-history decision

    @Test func thinHistoryVerdicts() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // No past events at all means history is not thin. An
        // empty five-year lookback is what an empty calendar looks like, not
        // evidence of a truncated sync window; the old `true` here warned
        // users about a cap that wasn't there and pointed them at a sync
        // setting that would have changed nothing.
        #expect(!CalendarEnricher.isThinHistory(earliestEvent: nil, now: now))
        // Earliest event 10 days back — the shape of a "1 month back" sync cap.
        #expect(CalendarEnricher.isThinHistory(earliestEvent: now.addingTimeInterval(-10 * 86_400), now: now))
        // Earliest event 2 years back → healthy.
        #expect(!CalendarEnricher.isThinHistory(earliestEvent: now.addingTimeInterval(-730 * 86_400), now: now))
    }

    // MARK: - Reconcile persists + preserves resolution

    @Test func applyScanWritesAndPreservesResolvedFields() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        let start = Date(timeIntervalSince1970: 1_822_419_200)
        let event = CalendarEventSnapshot(
            externalIdentifier: "ext", localIdentifier: "loc", title: "Trip to Rome",
            notes: nil, locationText: "Rome, Italy",
            startDate: start, endDate: start.addingTimeInterval(3 * 86_400),
            isAllDay: false, hasRecurrenceRules: false, isDetached: false,
            calendarTitle: "Personal", calendarKind: .icloud
        )
        let place = ForwardGeocodedPlace(latitude: 41.89, longitude: 12.51, locality: "Rome", country: "Italy", isoCountryCode: "IT")
        let resolvedDetection = PlannedTripDetection(
            snapshot: event, confidence: .high, signals: ["bookingTitle"],
            resolved: ResolvedPlannedPlace(place: place, distanceFromHomeKm: 1052)
        )

        let now = start.addingTimeInterval(-30 * 86_400)
        await enricher.applyScan(detections: [resolvedDetection], now: now)

        let context = ModelContext(container)
        var row = try #require(try context.fetch(FetchDescriptor<PlannedTrip>()).first)
        #expect(row.resolvedLocality == "Rome")
        #expect(row.resolvedISOCountryCode == "IT")
        #expect(row.distanceFromHomeKm == 1052)

        // A later scan that couldn't resolve (budget/offline) must keep the
        // earlier resolution.
        let unresolvedDetection = PlannedTripDetection(snapshot: event, confidence: .high, signals: ["bookingTitle"])
        await enricher.applyScan(detections: [unresolvedDetection], now: now.addingTimeInterval(3600))
        row = try #require(try context.fetch(FetchDescriptor<PlannedTrip>()).first)
        #expect(row.resolvedLocality == "Rome")
        #expect(row.distanceFromHomeKm == 1052)
    }

    @Test func definitiveRejectionClearsLegacyGeographyAndForecast() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let start = Date(timeIntervalSince1970: 1_822_419_200)
        let scanNow = start.addingTimeInterval(-30 * 86_400)
        let event = CalendarEventSnapshot(
            externalIdentifier: "legacy-ext", localIdentifier: "legacy-loc",
            title: "Grandma's place", notes: nil, locationText: "Conference Room 4b",
            startDate: start, endDate: start.addingTimeInterval(3 * 86_400),
            isAllDay: false, hasRecurrenceRules: false, isDetached: false,
            calendarTitle: "Personal", calendarKind: .icloud
        )

        let seedContext = ModelContext(container)
        let row = PlannedTrip(
            eventExternalIdentifier: event.externalIdentifier,
            eventLocalIdentifier: event.localIdentifier,
            title: event.title,
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: false,
            locationText: event.locationText
        )
        row.resolvedLatitude = 40.6839
        row.resolvedLongitude = -74.0282
        row.resolvedLocality = "New York"
        row.resolvedCountry = "United States"
        row.resolvedISOCountryCode = "US"
        row.distanceFromHomeKm = 7_900
        row.confidence = .medium
        row.signals = [PlannedTripDetector.signalFarFromHome, PlannedTripDetector.signalMultiDay]
        row.lastSeenAt = scanNow
        row.forecast = PlannedTripForecast(
            fetchedAt: start,
            days: [.init(
                date: start,
                conditionRaw: "clear",
                minTemperatureC: 10,
                maxTemperatureC: 20,
                precipitationMm: 0
            )]
        )
        seedContext.insert(row)
        try seedContext.save()

        let enricher = CalendarEnricher(modelContainer: container)
        await enricher.applyScan(
            detections: [],
            rejectedGeocodes: [event],
            now: scanNow
        )

        let verifyContext = ModelContext(container)
        let healed = try #require(try verifyContext.fetch(FetchDescriptor<PlannedTrip>()).first)
        #expect(healed.resolvedLatitude == nil)
        #expect(healed.resolvedLongitude == nil)
        #expect(healed.resolvedLocality == nil)
        #expect(healed.resolvedCountry == nil)
        #expect(healed.resolvedISOCountryCode == nil)
        #expect(healed.distanceFromHomeKm == nil)
        #expect(healed.forecast == nil)
        #expect(!healed.signals.contains(PlannedTripDetector.signalFarFromHome))
        #expect(healed.confidence == .low)
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
