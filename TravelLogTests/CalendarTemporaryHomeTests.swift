//
//  CalendarTemporaryHomeTests.swift
//  TravelLogTests
//
//  Calendar events are measured from the nearest home active on the event's
//  date. A temporary home counts inside its own dates, future ones included,
//  so an event at the base during a semester is not 2,000 km "from home",
//  while the same event before or after the semester still is.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite(.serialized, IsolatedCalendarDefaults())
struct CalendarTemporaryHomeTests {

    nonisolated private static let brussels = ForwardGeocodedPlace(latitude: 50.8242, longitude: 4.2747,
        locality: "Brussels", country: "Belgium", isoCountryCode: "BE")

    /// The temporary home's dates.
    private let start = Date(timeIntervalSinceReferenceDate: 837_904_000)
    private var end: Date { start.addingTimeInterval(150 * 86_400) }

    private var inside: Date { start.addingTimeInterval(30 * 86_400) }
    private var before: Date { start.addingTimeInterval(-30 * 86_400) }
    private var after: Date { end.addingTimeInterval(30 * 86_400) }

    /// A booking title is a detection on its own text, so the scan reports
    /// its measured distance whatever that distance is.
    private func flight(at date: Date) -> CalendarEventSnapshot {
        CalendarEventSnapshot(externalIdentifier: "flight", localIdentifier: "flight", title: "Flight to Brussels",
            notes: nil, locationText: "Brussels, Belgium", startDate: date, endDate: date.addingTimeInterval(3 * 3_600),
            isAllDay: false, hasRecurrenceRules: false, isDetached: false, calendarTitle: "Test", calendarKind: .icloud)
    }

    /// No travel vocabulary: only the distance from home makes it a trip.
    private func offsite(at date: Date) -> CalendarEventSnapshot {
        CalendarEventSnapshot(externalIdentifier: "offsite", localIdentifier: "offsite", title: "Team offsite",
            notes: nil, locationText: "Brussels, Belgium", startDate: date, endDate: date.addingTimeInterval(3 * 86_400),
            isAllDay: false, hasRecurrenceRules: false, isDetached: false, calendarTitle: "Test", calendarKind: .icloud)
    }

    private func makeEnricher(withTemporaryHome: Bool) throws -> CalendarEnricher {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(Home(label: "Home", latitude: 37.98376, longitude: 23.72784,
                            startedAt: start.addingTimeInterval(-1_000 * 86_400)))
        if withTemporaryHome {
            context.insert(TemporaryHome(
                label: "Erasmus", latitude: 50.8242, longitude: 4.2747, startedAt: start, endedAt: end))
        }
        try context.save()
        return CalendarEnricher(modelContainer: container)
    }

    private func scan(_ enricher: CalendarEnricher, _ snapshot: CalendarEventSnapshot) async -> CalendarEnricher.ScanAnalysis {
        let epoch = await enricher.calendarDataEpochForTesting()
        return await enricher.resolveAndAugment(
            detections: PlannedTripDetector.detect(in: [snapshot]), allSnapshots: [snapshot],
            allowFMTieBreaker: false, allowNetworkResolution: false, expectedEpoch: epoch,
            cacheLookup: { _ in .resolved(Self.brussels) },
            resolve: { _, _, _ in .resolved(Self.brussels) })
    }

    /// The distance the scan stores on the event's card.
    private func distanceFromHome(_ enricher: CalendarEnricher, at date: Date) async throws -> Double {
        let analysis = await scan(enricher, flight(at: date))
        #expect(analysis.isComplete)
        let detection = try #require(analysis.detections.first)
        return try #require(detection.resolved?.distanceFromHomeKm)
    }

    @Test("an event at the base inside the temporary home's dates measures from the base")
    func eventInsideDatesMeasuresFromTheBase() async throws {
        let enricher = try makeEnricher(withTemporaryHome: true)
        #expect(try await distanceFromHome(enricher, at: inside) < 1)
    }

    @Test("the same event before the start or after the end measures from the real Home")
    func eventOutsideDatesMeasuresFromTheRealHome() async throws {
        let enricher = try makeEnricher(withTemporaryHome: true)
        #expect(try await distanceFromHome(enricher, at: before) > 2_000)
        #expect(try await distanceFromHome(enricher, at: after) > 2_000)
    }

    @Test("with no temporary home every date measures from the real Home, as before")
    func noTemporaryHomeMeasuresFromTheRealHome() async throws {
        let enricher = try makeEnricher(withTemporaryHome: false)
        let athens = [CalendarEnricher.HomeSnapshot(
            latitude: 37.98376, longitude: 23.72784,
            startedAt: start.addingTimeInterval(-1_000 * 86_400), endedAt: nil)]
        for date in [before, inside, after] {
            let expected = try #require(CalendarEnricher.distanceFromActiveHome(
                athens, at: date, latitude: Self.brussels.latitude, longitude: Self.brussels.longitude))
            let measured = try await distanceFromHome(enricher, at: date)
            #expect(measured > 2_000)
            #expect(abs(measured - expected) < 0.01)
        }
    }

    @Test("an offsite at the base is an upcoming trip only outside the temporary home's dates")
    func offsiteAtTheBaseIsATripOnlyOutsideTheDates() async throws {
        let enricher = try makeEnricher(withTemporaryHome: true)

        let during = await scan(enricher, offsite(at: inside))
        #expect(during.isComplete)
        #expect(during.detections.isEmpty)

        for date in [before, after] {
            let outside = await scan(enricher, offsite(at: date))
            let detection = try #require(outside.detections.first)
            #expect(detection.signals.contains(PlannedTripDetector.signalFarFromHome))
        }
    }
}

// MARK: - Home distance

extension CalendarTemporaryHomeTests {

    @Test func distanceUsesHomeActiveAtDate() {
        let t0 = Date(timeIntervalSince1970: 1_602_419_200)
        let t1 = Date(timeIntervalSince1970: 1_702_419_200)
        // Old home: Athens (ended at t1). Current home: Berlin.
        let homes = [
            CalendarEnricher.HomeSnapshot(latitude: 37.98, longitude: 23.72, startedAt: t0, endedAt: t1),
            CalendarEnricher.HomeSnapshot(latitude: 52.52, longitude: 13.40, startedAt: t1, endedAt: nil),
        ]
        // A point in Athens: ~0 km from the OLD home for a date before t1,
        // far from the CURRENT home for a date after it.
        let before = CalendarEnricher.distanceFromActiveHome(homes, at: t1.addingTimeInterval(-1), latitude: 37.98, longitude: 23.72)
        let after = CalendarEnricher.distanceFromActiveHome(homes, at: t1.addingTimeInterval(1), latitude: 37.98, longitude: 23.72)
        #expect((before ?? 999) < 1)
        #expect((after ?? 0) > 1000)

        // No home covering the date → nil.
        #expect(CalendarEnricher.distanceFromActiveHome(homes, at: t0.addingTimeInterval(-1), latitude: 0, longitude: 0) == nil)
    }
}
