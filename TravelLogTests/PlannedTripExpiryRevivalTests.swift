//
//  PlannedTripExpiryRevivalTests.swift
//  TravelLogTests
//
//  `.expired` means the source dates passed. A current detection
//  whose refreshed dates are current again returns the row to `.upcoming`,
//  for timed rows as well as all-day ones; matched and dismissed rows stay
//  terminal, and a failed reconcile save commits nothing later.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite(.serialized, IsolatedCalendarDefaults())
struct PlannedTripExpiryRevivalTests {

    private let start = Date(timeIntervalSinceReferenceDate: 850_000_000)
    private let zone = TimeZone(secondsFromGMT: 0)!

    private func snapshot(durationHours: Double, id: String = "hotel") -> CalendarEventSnapshot {
        CalendarEventSnapshot(
            externalIdentifier: id, localIdentifier: id, title: "Hotel Lisboa",
            notes: nil, locationText: nil,
            startDate: start, endDate: start.addingTimeInterval(durationHours * 3600),
            isAllDay: false, hasRecurrenceRules: false, isDetached: false,
            calendarTitle: "Test", calendarKind: .icloud)
    }

    private func detection(_ snapshot: CalendarEventSnapshot) -> PlannedTripDetection {
        PlannedTripDetection(snapshot: snapshot, confidence: .high, signals: ["bookingTitle"])
    }

    private func rows(_ container: ModelContainer) throws -> [PlannedTrip] {
        try ModelContext(container).fetch(FetchDescriptor<PlannedTrip>())
    }

    /// The widget / Next Trip intent read: upcoming and still current.
    private func upcomingFeed(_ container: ModelContainer, now: Date) throws -> [PlannedTrip] {
        let predicate = #Predicate<PlannedTrip> { $0.statusRaw == "upcoming" }
        return try ModelContext(container).fetch(FetchDescriptor<PlannedTrip>(predicate: predicate))
            .filter { $0.currentUntil(timeZone: zone) >= now }
    }

    @Test("a timed booking extended after lifecycle expiry returns to the upcoming feeds")
    func extendedTimedBookingRevivesAfterRealExpiry() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        await enricher.applyScan(detections: [detection(snapshot(durationHours: 48))],
                                 now: start.addingTimeInterval(-86_400), timeZone: zone)

        // Another device (or this one before the edit synced) retires it on
        // the old end: no trip matched, grace elapsed.
        let expiredAt = start.addingTimeInterval(48 * 3600 + CalendarEnricher.expiryGraceSeconds + 3600)
        await enricher.applyScan(detections: [], now: expiredAt, timeZone: zone)
        #expect(try rows(container).first?.status == .expired)

        let extended = snapshot(durationHours: 10 * 24)
        let later = expiredAt.addingTimeInterval(3600)
        #expect(await enricher.applyScan(detections: [detection(extended)], now: later, timeZone: zone))
        let revived = try #require(try rows(container).first)
        #expect(revived.status == .upcoming)
        #expect(revived.endDate == extended.endDate)
        #expect(try upcomingFeed(container, now: later).count == 1)

        // A follow-up scan that still sees it keeps it; nothing sweeps it.
        await enricher.applyScan(detections: [detection(extended)], now: later, timeZone: zone)
        #expect(try rows(container).map(\.status) == [.upcoming])
    }

    @Test("a leg expired while its dismissal waited in the gate stays dismissed when the event is extended")
    func dismissalQueuedBehindExpiryStaysDismissed() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        await enricher.applyScan(detections: [detection(snapshot(durationHours: 48))],
                                 now: start.addingTimeInterval(-86_400), timeZone: zone)
        // The card the user taps carries the leg ID read while it was upcoming.
        let legID = try #require(try rows(container).first?.id)

        // A unit ahead of the dismissal in the gate retires the leg on its old end.
        let expiredAt = start.addingTimeInterval(48 * 3600 + CalendarEnricher.expiryGraceSeconds + 3600)
        await enricher.applyScan(detections: [], now: expiredAt, timeZone: zone)
        #expect(try rows(container).first?.status == .expired)

        let ids: Set<UUID> = [legID]
        let saved = await PipelineGate.shared.runReturning(touching: [.plannedTrip]) {
            await TripsListView.dismissPlannedTrips(ids: ids, container: container)
        }
        #expect(saved)
        #expect(try rows(container).first?.status == .dismissed)

        // The same event extended to current dates must not bring the card back.
        let extended = snapshot(durationHours: 10 * 24)
        let later = expiredAt.addingTimeInterval(3600)
        #expect(await enricher.applyScan(detections: [detection(extended)], now: later, timeZone: zone))
        let kept = try #require(try rows(container).first)
        #expect(kept.id == legID)
        #expect(kept.status == .dismissed)
        #expect(kept.endDate == extended.endDate)
        #expect(try upcomingFeed(container, now: later).isEmpty)
    }

    @Test("an installed row left expired with an already-refreshed end heals on the next detection")
    func stuckRowWithRefreshedEndHeals() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let extended = snapshot(durationHours: 10 * 24)
        let context = ModelContext(container)
        let row = PlannedTrip(eventExternalIdentifier: "hotel", eventLocalIdentifier: "hotel",
            title: "Hotel Lisboa", startDate: extended.startDate, endDate: extended.endDate,
            isAllDay: false, locationText: nil)
        row.status = .expired
        context.insert(row)
        try context.save()

        let enricher = CalendarEnricher(modelContainer: container)
        let now = start.addingTimeInterval(5 * 86_400)
        await enricher.applyScan(detections: [detection(extended)], now: now, timeZone: zone)
        #expect(try rows(container).first?.status == .upcoming)
    }

    @Test("dismissed, matched, undetected and still-past expired rows keep their status")
    func terminalAndPastRowsAreNotRevived() async throws {
        let now = start.addingTimeInterval(5 * 86_400)
        let extended = snapshot(durationHours: 10 * 24)
        let tripID = UUID()
        for status in [PlannedTripStatus.dismissed, .matched] {
            let container = try TestSupport.makeInMemoryContainer()
            let context = ModelContext(container)
            let row = PlannedTrip(eventExternalIdentifier: "hotel", eventLocalIdentifier: "hotel",
                title: "Hotel Lisboa", startDate: start, endDate: start.addingTimeInterval(48 * 3600),
                isAllDay: false, locationText: nil)
            row.status = status
            if status == .matched { row.matchedTripID = tripID }
            context.insert(row)
            try context.save()
            let enricher = CalendarEnricher(modelContainer: container)
            await enricher.applyScan(detections: [detection(extended)], now: now, timeZone: zone)
            let saved = try #require(try rows(container).first)
            #expect(saved.status == status)
            if status == .matched { #expect(saved.matchedTripID == tripID) }
        }

        // No current detection, or a detection whose dates are still past.
        for detected in [false, true] {
            let container = try TestSupport.makeInMemoryContainer()
            let context = ModelContext(container)
            let row = PlannedTrip(eventExternalIdentifier: "hotel", eventLocalIdentifier: "hotel",
                title: "Hotel Lisboa", startDate: start, endDate: start.addingTimeInterval(48 * 3600),
                isAllDay: false, locationText: nil)
            row.status = .expired
            context.insert(row)
            try context.save()
            let enricher = CalendarEnricher(modelContainer: container)
            let past = snapshot(durationHours: 72)
            await enricher.applyScan(detections: detected ? [detection(past)] : [], now: now, timeZone: zone)
            #expect(try rows(container).first?.status == .expired)
        }
    }

    @Test("a revival whose save fails rolls back, and a later save cannot commit it")
    func failedRevivalSaveRollsBack() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let row = PlannedTrip(eventExternalIdentifier: "hotel", eventLocalIdentifier: "hotel",
            title: "Hotel Lisboa", startDate: start, endDate: start.addingTimeInterval(48 * 3600),
            isAllDay: false, locationText: nil)
        row.status = .expired
        context.insert(row)
        try context.save()
        let enricher = CalendarEnricher(modelContainer: container)
        let now = start.addingTimeInterval(5 * 86_400)

        await enricher.failNextScanSave()
        let applied = await enricher.applyScan(
            detections: [detection(snapshot(durationHours: 10 * 24))], now: now, timeZone: zone)
        #expect(!applied)
        #expect(try rows(container).first?.status == .expired)

        // An unrelated detection's successful save must not carry the failed
        // revival with it.
        let other = CalendarEventSnapshot(
            externalIdentifier: "other", localIdentifier: "other", title: "Hotel Porto",
            notes: nil, locationText: nil,
            startDate: now.addingTimeInterval(30 * 86_400), endDate: now.addingTimeInterval(32 * 86_400),
            isAllDay: false, hasRecurrenceRules: false, isDetached: false,
            calendarTitle: "Test", calendarKind: .icloud)
        #expect(await enricher.applyScan(detections: [detection(other)], now: now, timeZone: zone))
        let saved = try rows(container)
        #expect(saved.count == 2)
        let original = try #require(saved.first { $0.eventLocalIdentifier == "hotel" })
        #expect(original.status == .expired)
        #expect(original.endDate == start.addingTimeInterval(48 * 3600))
    }
}
