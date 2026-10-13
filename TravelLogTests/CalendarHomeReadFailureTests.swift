//
//  CalendarHomeReadFailureTests.swift
//  TravelLogTests
//
//  A failed Home read is not "no Home". The calendar scan
//  scores far-from-home evidence from Home distance, and an accepted
//  near-miss without that evidence withdraws a row's place and forecast, so
//  a scan whose Home read fails must not reconcile at all.
//

import Foundation
import EventKit
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite(.serialized, IsolatedCalendarDefaults())
struct CalendarHomeReadFailureTests {

    nonisolated private static let berlin = ForwardGeocodedPlace(latitude: 52.55284, longitude: 13.43930,
        locality: "Berlin", country: "Germany", isoCountryCode: "DE")

    private var defaults: UserDefaults { IsolatedCalendarDefaults.current }

    private func offsite() -> CalendarEventSnapshot {
        let start = Date.now.addingTimeInterval(30 * 86_400)
        return CalendarEventSnapshot(externalIdentifier: "offsite", localIdentifier: "offsite", title: "Team offsite",
            notes: nil, locationText: "Berlin, Germany", startDate: start, endDate: start.addingTimeInterval(3 * 86_400),
            isAllDay: false, hasRecurrenceRules: false, isDetached: false, calendarTitle: "Test", calendarKind: .icloud)
    }

    private func seedAthensHome(_ container: ModelContainer) throws {
        let context = ModelContext(container)
        context.insert(Home(label: "Home", latitude: 37.92324, longitude: 23.77200,
                            startedAt: Date.now.addingTimeInterval(-365 * 86_400)))
        try context.save()
    }

    private func scan(_ enricher: CalendarEnricher, _ snapshot: CalendarEventSnapshot,
                      failHomeFetch: Bool) async -> CalendarEnricher.ScanAnalysis {
        let epoch = await enricher.calendarDataEpochForTesting()
        return await CalendarEnricher.TestScope.$failHomeFetch.withValue(failHomeFetch) {
            await enricher.resolveAndAugment(
                detections: PlannedTripDetector.detect(in: [snapshot]), allSnapshots: [snapshot],
                allowFMTieBreaker: false, allowNetworkResolution: false, expectedEpoch: epoch,
                cacheLookup: { _ in .resolved(Self.berlin) },
                resolve: { _, _, _ in .resolved(Self.berlin) })
        }
    }

    @Test("a failed Home read returns an incomplete scan instead of withdrawing an accepted near-miss")
    func failedHomeReadDoesNotWithdrawAcceptedNearMiss() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        try seedAthensHome(container)
        let enricher = CalendarEnricher(modelContainer: container)
        let event = offsite()

        // Healthy scan: only the Home distance makes this event a detection.
        #expect(PlannedTripDetector.detect(in: [event]).isEmpty)
        let healthy = await scan(enricher, event, failHomeFetch: false)
        #expect(healthy.isComplete)
        let detection = try #require(healthy.detections.first)
        #expect(detection.signals.contains(PlannedTripDetector.signalFarFromHome))
        #expect(healthy.rejectedGeocodes.isEmpty)
        await enricher.applyScan(detections: healthy.detections, rejectedGeocodes: healthy.rejectedGeocodes,
            deferredGroundingSnapshots: healthy.deferredGroundingSnapshots, now: .now)

        // The Home read fails: no withdrawal instruction and nothing to reconcile.
        let failed = await scan(enricher, event, failHomeFetch: true)
        #expect(!failed.isComplete)
        #expect(failed.detections.isEmpty)
        #expect(failed.rejectedGeocodes.isEmpty)
        #expect(failed.deferredGroundingSnapshots.isEmpty)

        // The stored card keeps its place and evidence, and a healthy retry
        // re-detects it unchanged.
        let row = try #require(try ModelContext(container).fetch(FetchDescriptor<PlannedTrip>()).first)
        #expect(row.resolvedISOCountryCode == "DE")
        #expect((row.distanceFromHomeKm ?? 0) > 1_000)
        #expect(row.signals.contains(PlannedTripDetector.signalFarFromHome))
        #expect(row.confidence != .low)
        let retried = await scan(enricher, event, failHomeFetch: false)
        #expect(retried.isComplete)
        #expect(retried.detections.first?.signals.contains(PlannedTripDetector.signalFarFromHome) == true)
    }

    @Test("both scan entry points skip the reconcile after a failed Home read, and the foreground scan stays due")
    func failedHomeReadSkipsReconcileAndKeepsScanDue() async throws {
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
        // Keep the thin-history probe away from EventKit.
        defaults.set(true, forKey: CalendarEnricher.thinHistoryProbeCompletedKey)
        defaults.set(["A"], forKey: CalendarEnricher.selectedCalendarIDsKey)
        let live = [CalendarEnricher.CalendarChoice(id: "A", title: "Travel", accountTitle: "Google")]
        let now = Date.now
        await enricher.recordCompletedScanForTesting(at: now)
        #expect(!(await enricher.activationScanIsDueForTesting(now: now.addingTimeInterval(60))))

        func runScan(failHomeFetch: Bool, ungated: Bool) async {
            await CalendarEnricher.TestScope.$authorizationStatus.withValue(.fullAccess) {
                await CalendarEnricher.TestScope.$liveCalendars.withValue(live) {
                    await CalendarEnricher.TestScope.$failHomeFetch.withValue(failHomeFetch) {
                        if ungated {
                            await enricher.scanUpcomingTripsUngated()
                        } else {
                            await enricher.scanUpcomingTrips()
                        }
                    }
                }
            }
        }

        // The empty event list would stale-sweep the row; an incomplete scan
        // is no evidence, so neither entry point reconciles it.
        await runScan(failHomeFetch: true, ungated: false)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PlannedTrip>()) == 1)
        #expect(await enricher.activationScanIsDueForTesting(now: now.addingTimeInterval(60)))
        await runScan(failHomeFetch: true, ungated: true)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PlannedTrip>()) == 1)

        // Control: a readable Home table makes the empty scan authoritative.
        await runScan(failHomeFetch: false, ungated: false)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PlannedTrip>()) == 0)
        #expect(!(await enricher.activationScanIsDueForTesting(now: Date.now.addingTimeInterval(60))))
    }
}
