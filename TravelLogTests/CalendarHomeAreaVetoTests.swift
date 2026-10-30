//
//  CalendarHomeAreaVetoTests.swift
//  TravelLogTests
//
//  The calendar tie-breaker's positive verdict never makes a card of an
//  event whose grounded destination lies inside the home area at the
//  event's time, cached verdicts included. Invented places only.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

// Extend the serialized suite: these tests share its judgment-cache defaults.
extension CalendarEnricherScanTests {

    /// The home is at 10, 20. About 3 km from it: inside its 25 km area.
    nonisolated private static let nearHome = ForwardGeocodedPlace(latitude: 10.02, longitude: 20.02,
        locality: "Brookfield", country: nil, isoCountryCode: nil)
    /// About 55 km away: outside the area, too near to be far-from-home evidence.
    nonisolated private static let nearby = ForwardGeocodedPlace(latitude: 10.5, longitude: 20.0,
        locality: "Varnhold", country: nil, isoCountryCode: nil)
    /// About 310 km away.
    nonisolated private static let away = ForwardGeocodedPlace(latitude: 12.0, longitude: 22.0,
        locality: "Varnhold", country: nil, isoCountryCode: nil)

    nonisolated private static func vetoEvent(_ title: String, location: String? = nil) -> CalendarEventSnapshot {
        let start = Date.now.addingTimeInterval(240 * 86_400)
        return CalendarEventSnapshot(externalIdentifier: "veto", localIdentifier: "veto", title: title,
            notes: nil, locationText: location, startDate: start, endDate: start.addingTimeInterval(48 * 3600),
            isAllDay: false, hasRecurrenceRules: false, isDetached: false, calendarTitle: "Test", calendarKind: .icloud)
    }

    private func seedVetoHome(_ container: ModelContainer, latitude: Double = 10, longitude: Double = 20) throws {
        let context = ModelContext(container)
        context.insert(Home(label: "Home", latitude: latitude, longitude: longitude,
                            startedAt: Date.now.addingTimeInterval(-365 * 86_400)))
        try context.save()
    }

    private func vetoScan(
        _ enricher: CalendarEnricher, _ event: CalendarEventSnapshot,
        places: [String: ForwardGeocodedPlace],
        judge: @escaping @Sendable (CalendarEventSnapshot) async -> PlannedTripJudgment?,
        homeAreas: (@Sendable () async throws -> [TripClassifier.HomeRing])? = nil
    ) async -> CalendarEnricher.ScanAnalysis {
        let epoch = await enricher.calendarDataEpochForTesting()
        return await enricher.resolveAndAugment(detections: PlannedTripDetector.detect(in: [event]),
            allSnapshots: [event], allowFMTieBreaker: true, allowNetworkResolution: true, expectedEpoch: epoch,
            cacheLookup: { places[$0].map { .resolved($0) } ?? .miss },
            resolve: { text, _, _ in places[text].map { .resolved($0) } ?? .rejected },
            judge: judge, homeAreas: homeAreas)
    }

    private func applyVeto(_ analysis: CalendarEnricher.ScanAnalysis, _ enricher: CalendarEnricher) async {
        await enricher.applyScan(detections: analysis.detections, rejectedGeocodes: analysis.rejectedGeocodes,
            deferredGroundingSnapshots: analysis.deferredGroundingSnapshots, now: .now)
    }

    nonisolated private static func trip(to destination: String) -> PlannedTripJudgment {
        PlannedTripJudgment(reasoning: "Fixture", isTrip: true, destination: destination)
    }

    @Test("a positive verdict whose destination is inside the home area makes no card")
    func positiveInsideHomeAreaMakesNoCard() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        try seedVetoHome(container)
        let enricher = CalendarEnricher(modelContainer: container)
        await enricher.clearFMJudgmentCache()
        let event = Self.vetoEvent("Brookfield wedding")
        #expect(PlannedTripDetector.detect(in: [event]).isEmpty)

        let analysis = await vetoScan(enricher, event, places: ["Brookfield": Self.nearHome],
                                      judge: { _ in Self.trip(to: "Brookfield") })
        #expect(analysis.detections.isEmpty)
        #expect(analysis.deferredGroundingSnapshots.isEmpty)
        #expect(analysis.rejectedGeocodes == [event])
        await applyVeto(analysis, enricher)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PlannedTrip>()) == 0)
    }

    @Test("a positive verdict whose destination is outside the home area makes a card")
    func positiveOutsideHomeAreaMakesCard() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        try seedVetoHome(container)
        let enricher = CalendarEnricher(modelContainer: container)
        await enricher.clearFMJudgmentCache()
        let event = Self.vetoEvent("Varnhold wedding")

        let analysis = await vetoScan(enricher, event, places: ["Varnhold": Self.away],
                                      judge: { _ in Self.trip(to: "Varnhold") })
        let detection = try #require(analysis.detections.first)
        #expect(detection.resolved?.place == Self.away)
        #expect(detection.signals.contains(PlannedTripDetector.signalFMTieBreaker))
        await applyVeto(analysis, enricher)
        let row = try #require(try ModelContext(container).fetch(FetchDescriptor<PlannedTrip>()).first)
        #expect(row.confidence == .medium)
    }

    @Test("a cached positive verdict is vetoed again after a Home moves next to its destination")
    func cachedPositiveIsVetoedAfterHomeChange() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        try seedVetoHome(container, latitude: 40.0, longitude: 20.0)
        let enricher = CalendarEnricher(modelContainer: container)
        await enricher.clearFMJudgmentCache()
        let event = Self.vetoEvent("Brookfield wedding")
        let places = ["Brookfield": Self.nearHome]

        let first = await vetoScan(enricher, event, places: places, judge: { _ in Self.trip(to: "Brookfield") })
        #expect(first.detections.count == 1)
        await applyVeto(first, enricher)
        let row = try #require(try ModelContext(container).fetch(FetchDescriptor<PlannedTrip>()).first)
        #expect(row.confidence == .medium)

        // The user's Home is now beside the destination.
        try seedVetoHome(container)
        let second = await vetoScan(enricher, event, places: places, judge: { _ in
            Issue.record("A cached verdict asked the model again")
            return nil
        })
        #expect(second.detections.isEmpty)
        #expect(second.rejectedGeocodes == [event])
        await applyVeto(second, enricher)
        let vetoed = try #require(try ModelContext(container).fetch(FetchDescriptor<PlannedTrip>()).first)
        #expect(vetoed.confidence == .low)
        #expect(vetoed.resolvedLatitude == nil)
        #expect(vetoed.distanceFromHomeKm == nil)
    }

    @Test("a departure venue beside home never vetoes an away destination the event names")
    func departureVenueNearHomeDoesNotVetoAwayDestination() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        try seedVetoHome(container)
        let enricher = CalendarEnricher(modelContainer: container)
        await enricher.clearFMJudgmentCache()

        // The location is the venue beside home; the model names the away destination.
        let leaving = Self.vetoEvent("Varnhold wedding", location: "Brookfield Hall")
        let fromVenue = await vetoScan(enricher, leaving,
            places: ["Brookfield Hall": Self.nearHome, "Varnhold": Self.nearby],
            judge: { _ in Self.trip(to: "Varnhold") })
        #expect(fromVenue.detections.first?.resolved?.place == Self.nearby)

        // The model names the venue beside home; the location outside the area stands.
        await enricher.clearFMJudgmentCache()
        let named = Self.vetoEvent("Brookfield wedding", location: "Varnhold Manor")
        #expect(PlannedTripDetector.detect(in: [named]).isEmpty)
        let fromLocation = await vetoScan(enricher, named,
            places: ["Varnhold Manor": Self.nearby, "Brookfield": Self.nearHome],
            judge: { _ in Self.trip(to: "Brookfield") })
        #expect(fromLocation.detections.first?.resolved?.place == Self.nearby)
        #expect(fromLocation.rejectedGeocodes.isEmpty)
    }

    @Test("unreadable home areas defer the event instead of deciding it")
    func unreadableHomeAreasDefer() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        try seedVetoHome(container)
        let enricher = CalendarEnricher(modelContainer: container)
        await enricher.clearFMJudgmentCache()
        let event = Self.vetoEvent("Varnhold wedding")

        let analysis = await vetoScan(enricher, event, places: ["Varnhold": Self.away],
            judge: { _ in Self.trip(to: "Varnhold") },
            homeAreas: { throw CocoaError(.fileReadUnknown) })
        #expect(analysis.detections.isEmpty)
        #expect(analysis.deferredGroundingSnapshots == [event])
        #expect(analysis.rejectedGeocodes.isEmpty)
    }
}
