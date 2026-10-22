import EventKit
import Foundation
import SwiftData
import Testing
@testable import TravelLog

// Shares the scan suite's serialization and isolated calendar defaults.
extension CalendarEnricherScanTests {
    private func seedFuturePlannedTrips(in container: ModelContainer) throws {
        let context = ModelContext(container)
        let start = Date.now.addingTimeInterval(7 * 86400)
        let end = start.addingTimeInterval(3 * 86400)
        let dismissed = PlannedTrip(eventExternalIdentifier: "synced-dismissed",
            eventLocalIdentifier: "synced-dismissed", title: "Trip to Rome",
            startDate: start, endDate: end, isAllDay: false, locationText: nil)
        dismissed.status = .dismissed
        context.insert(dismissed)
        context.insert(PlannedTrip(eventExternalIdentifier: "synced-upcoming",
            eventLocalIdentifier: "synced-upcoming", title: "Trip to Paris",
            startDate: start, endDate: end, isAllDay: false, locationText: nil))
        try context.save()
    }

    @Test("A device that never asked for Calendar keeps future rows synced from another device")
    func undeterminedDeviceKeepsSyncedPlannedTrips() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        try seedFuturePlannedTrips(in: container)
        let enricher = CalendarEnricher(modelContainer: container)

        await CalendarEnricher.TestScope.$authorizationStatus.withValue(.notDetermined) {
            await enricher.scanUpcomingTrips()
        }

        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PlannedTrip>()) == 2)
        #expect(IsolatedCalendarDefaults.current.object(
            forKey: "calendarRevocationCleanupCompleted_v1") == nil)
    }

    @Test("A denied device without the grant latch still cleans its future rows once")
    func deniedPreLatchDeviceCleansFuturePlannedTrips() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        try seedFuturePlannedTrips(in: container)
        let enricher = CalendarEnricher(modelContainer: container)

        await CalendarEnricher.TestScope.$authorizationStatus.withValue(.denied) {
            await enricher.scanUpcomingTrips()
        }

        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PlannedTrip>()) == 0)
        #expect(IsolatedCalendarDefaults.current.bool(
            forKey: "calendarRevocationCleanupCompleted_v1"))
    }
}
