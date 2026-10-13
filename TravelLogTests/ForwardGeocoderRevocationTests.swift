import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
struct ForwardGeocoderRevocationTests {
    @Test("a pre-wipe scan that enters the geocoder after cache clearing cannot persist calendar text")
    func lateScanEntryCannotAdoptNewCacheGeneration() async throws {
        let suite = "ForwardGeocoderRevocationTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let geocoder = ForwardGeocoder(defaultsSuiteNameForTesting: suite)
        let enricher = CalendarEnricher(modelContainer: try TestSupport.makeInMemoryContainer())
        let start = Date(timeIntervalSinceReferenceDate: 850_000_000)
        let event = CalendarEventSnapshot(externalIdentifier: "late", localIdentifier: "late",
            title: "Trip to Rome", notes: nil, locationText: "Conference Room 4B",
            startDate: start, endDate: start.addingTimeInterval(3 * 86400), isAllDay: false,
            hasRecurrenceRules: false, isDetached: false, calendarTitle: "Test", calendarKind: .icloud)
        let epoch = await enricher.calendarDataEpochForTesting()
        await geocoder.setBeforeEntryForTesting {
            await enricher.beginCalendarDataRevocation()
            await geocoder.clearCache()
        }
        let result = await enricher.resolveAndAugment(detections: PlannedTripDetector.detect(in: [event]),
            allSnapshots: [event], allowFMTieBreaker: false, allowNetworkResolution: false,
            expectedEpoch: epoch, geocoder: geocoder)
        #expect(result.detections.isEmpty)
        #expect(await geocoder.cachedResolution(for: "Conference Room 4B") == .miss)
        #expect(UserDefaults(suiteName: suite)?.data(forKey: "forwardGeocodeCache_v4") == nil)
        // New work after revocation gets fresh authority and remains usable.
        #expect(await geocoder.resolveOutcome("Conference Room 4B", allowNetwork: false) == .rejected)
        #expect(await geocoder.cachedResolution(for: "Conference Room 4B") == .unresolved)
    }

    @Test("revocation after geocoder admission rejects publication")
    func revokedResolutionCannotPublish() async {
        let suite = "ForwardGeocoderRevocationTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let geocoder = ForwardGeocoder(defaultsSuiteNameForTesting: suite)
        let authority = ForwardGeocoder.RequestAuthority()
        await geocoder.setBeforePublicationForTesting {
            authority.revoke()
        }
        #expect(await geocoder.resolveOutcome("Conference Room 4B", allowNetwork: false,
                                               authority: authority) == .unavailable)
        #expect(await geocoder.cachedResolution(for: "Conference Room 4B") == .miss)
        #expect(UserDefaults(suiteName: suite)?.data(forKey: "forwardGeocodeCache_v4") == nil)
    }
}
