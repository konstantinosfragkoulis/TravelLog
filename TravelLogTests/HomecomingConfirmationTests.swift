//
//  HomecomingConfirmationTests.swift
//  TravelLogTests
//
//  The qualifying-home-boundary rule can delay closing a trip: a final
//  homecoming's live-SLC home stay is born zero-dwell, and its `endTime`
//  only advances when a later ping arrives, so for a user who comes home
//  and stays put, the finished trip lingered "ongoing" until their next
//  outing.
//
//  The fix requests ONE confirmation location fix (a measurement, never a
//  presumptive close) when — and only when — the store's terminal stay is
//  exactly that unconfirmed short-dwell home arrival and a trip is open.
//  These tests pin the decision rule's full matrix plus the actor wrapper's
//  store consultation and throttle.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
struct HomecomingConfirmationTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func needed(
        category: StayCategory = .home,
        source: DataSource = .liveSLC,
        dwellMinutes: Double = 0,
        wallClockMinutes: Double = 20,
        hasOpenTrip: Bool = true
    ) -> Bool {
        TripClassifier.homecomingConfirmationNeeded(
            terminalStayCategory: category,
            terminalStaySource: source,
            terminalStayStartTime: t0,
            terminalStayEndTime: t0.addingTimeInterval(dwellMinutes * 60),
            hasOpenTrip: hasOpenTrip,
            now: t0.addingTimeInterval(wallClockMinutes * 60)
        )
    }

    // MARK: - Decision-rule matrix

    @Test("fires for a zero-dwell live-SLC home terminal stay with an open trip")
    func firesOnUnconfirmedHomecoming() {
        #expect(needed())
    }

    @Test("never fires without an open trip — nothing to close")
    func noOpenTripNoRequest() {
        #expect(!needed(hasOpenTrip: false))
    }

    @Test("never fires for non-home terminal stays")
    func nonHomeNoRequest() {
        #expect(!needed(category: .destination))
        #expect(!needed(category: .transit))
        #expect(!needed(category: .unclassified))
    }

    @Test("imported home stays always qualify as boundaries already — no request")
    func importedSourceNoRequest() {
        #expect(!needed(source: .photoImport))
        #expect(!needed(source: .timelineImport))
        #expect(!needed(source: .gpxImport))
    }

    @Test("a stay that already accrued qualifying dwell needs no confirmation")
    func confirmedDwellNoRequest() {
        #expect(!needed(dwellMinutes: 15))
        #expect(!needed(dwellMinutes: 120))
    }

    @Test("does not fire before wall-clock dwell could reach the threshold")
    func tooEarlyNoRequest() {
        // A confirming fix now would still leave stored dwell below the
        // 15-minute boundary threshold — pointless request.
        #expect(!needed(wallClockMinutes: 10))
        // Boundary: exactly at the threshold fires.
        #expect(needed(wallClockMinutes: 15))
    }

    // MARK: - Actor wrapper

    @Test("store consult: fires exactly once, then throttles")
    func storeConsultAndThrottle() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // An open trip with one destination stay, then the zero-dwell
        // homecoming arrival as the terminal stay.
        let dest = Stay(
            startTime: t0.addingTimeInterval(-4 * 86_400),
            endTime: t0.addingTimeInterval(-4 * 86_400 + 6 * 3600),
            centroidLatitude: 0, centroidLongitude: 0,
            h3IndexRes6: "D", pingCount: 1,
            distanceFromHomeKm: 300, pingIDs: []
        )
        dest.category = .destination
        ctx.insert(dest)
        let trip = Trip(startDate: dest.startTime)
        ctx.insert(trip)
        dest.trip = trip
        dest.orderInTrip = 0

        let arrival = Stay(
            startTime: t0, endTime: t0,
            centroidLatitude: 0, centroidLongitude: 0,
            h3IndexRes6: "H", pingCount: 1,
            distanceFromHomeKm: 0, pingIDs: []
        )
        arrival.category = .home
        arrival.sourceRaw = DataSource.liveSLC.rawValue
        ctx.insert(arrival)
        try ctx.save()

        let checkTime = t0.addingTimeInterval(20 * 60)
        #expect(await classifier.homecomingConfirmationDue(now: checkTime))
        // Immediately after a granted request: throttled.
        #expect(!(await classifier.homecomingConfirmationDue(now: checkTime.addingTimeInterval(60))))
        // Past the throttle window (and still unconfirmed): fires again.
        let later = checkTime.addingTimeInterval(TripClassifier.homecomingConfirmationThrottleSeconds + 60)
        #expect(await classifier.homecomingConfirmationDue(now: later))
    }

    @Test("store consult: no open trip means no request even with the terminal-home shape")
    func storeConsultNoOpenTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let arrival = Stay(
            startTime: t0, endTime: t0,
            centroidLatitude: 0, centroidLongitude: 0,
            h3IndexRes6: "H", pingCount: 1,
            distanceFromHomeKm: 0, pingIDs: []
        )
        arrival.category = .home
        arrival.sourceRaw = DataSource.liveSLC.rawValue
        ctx.insert(arrival)
        try ctx.save()

        #expect(!(await classifier.homecomingConfirmationDue(now: t0.addingTimeInterval(20 * 60))))
    }

    @Test("store consult: a later stay after the home arrival disqualifies it")
    func storeConsultTerminalOnly() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let trip = Trip(startDate: t0.addingTimeInterval(-4 * 86_400))
        trip.isComplete = false
        ctx.insert(trip)

        // A phantom home stay followed by later travel is not terminal,
        // so no confirmation request fires
        // (and the dwell gate keeps it from ever splitting the trip).
        let phantom = Stay(
            startTime: t0, endTime: t0,
            centroidLatitude: 0, centroidLongitude: 0,
            h3IndexRes6: "H", pingCount: 1,
            distanceFromHomeKm: 0, pingIDs: []
        )
        phantom.category = .home
        phantom.sourceRaw = DataSource.liveSLC.rawValue
        ctx.insert(phantom)

        let island = Stay(
            startTime: t0.addingTimeInterval(3600),
            endTime: t0.addingTimeInterval(2 * 3600),
            centroidLatitude: 0, centroidLongitude: 0,
            h3IndexRes6: "N", pingCount: 1,
            distanceFromHomeKm: 250, pingIDs: []
        )
        island.category = .destination
        ctx.insert(island)
        try ctx.save()

        #expect(!(await classifier.homecomingConfirmationDue(now: t0.addingTimeInterval(20 * 60))))
    }
}
