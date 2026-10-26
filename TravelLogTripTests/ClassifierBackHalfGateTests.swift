//
//  ClassifierBackHalfGateTests.swift
//  TravelLogTests
//
//  Phase 2 of the heat-architecture rework: the
//  pipeline back half (sanity-check → assemble → close) is dirty-gated so it
//  no longer re-materializes the Stay set on every Trips/Stays/Status-tab
//  visit. The gate is STALENESS-SAFE because, beyond "an upstream stage
//  changed a stay" and "first pass since launch", it also runs whenever the
//  stay↔trip invariant is violated — the exact residue a category override,
//  merge, delete, or import leaves behind. These tests pin that invariant
//  check (the guarantee that a skip can never strand a needed reassembly).
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Classifier back-half dirty-gate invariant")
struct ClassifierBackHalfGateTests {

    private static let day: TimeInterval = 24 * 60 * 60

    private func date(day offset: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: offset * Self.day)
    }

    @discardableResult
    private func makeStay(
        in ctx: ModelContext,
        startDay: Double,
        category: StayCategory,
        hex: String,
        trip: Trip? = nil,
        pingCount: Int = 1,
        durationHours: Double = 6
    ) -> Stay {
        let start = date(day: startDay)
        let stay = Stay(
            startTime: start,
            endTime: start.addingTimeInterval(durationHours * 3600),
            centroidLatitude: 0, centroidLongitude: 0,
            h3IndexRes6: hex, pingCount: pingCount,
            distanceFromHomeKm: 0, pingIDs: []
        )
        stay.category = category
        stay.trip = trip
        ctx.insert(stay)
        return stay
    }

    @discardableResult
    private func makeStay(
        in ctx: ModelContext,
        start: Date,
        end: Date,
        category: StayCategory,
        hex: String,
        trip: Trip? = nil,
        pingCount: Int = 1,
        source: DataSource = .liveSLC
    ) -> Stay {
        let stay = Stay(
            startTime: start,
            endTime: end,
            centroidLatitude: 0, centroidLongitude: 0,
            h3IndexRes6: hex, pingCount: pingCount,
            distanceFromHomeKm: 0, pingIDs: [], source: source
        )
        stay.category = category
        stay.trip = trip
        ctx.insert(stay)
        return stay
    }

    private func makeTrip(in ctx: ModelContext, startDay: Double) -> Trip {
        let trip = Trip(startDate: date(day: startDay))
        ctx.insert(trip)
        return trip
    }

    @Test("a qualifying home after an open trip makes closure due")
    func openTripClosureDueWhenQualifyingHomeFollowsOpenTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let trip = makeTrip(in: ctx, startDay: 0)
        makeStay(
            in: ctx, startDay: 0, category: .transit, hex: "T",
            trip: trip, durationHours: 24)
        makeStay(
            in: ctx, startDay: 2, category: .home, hex: "H",
            pingCount: 2, durationHours: 0.25)
        try ctx.save()

        #expect(await classifier.openTripClosureDue() == true)
    }

    @Test("a single-ping home after an open trip does not make closure due")
    func openTripClosureNotDueForSinglePingHome() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let trip = makeTrip(in: ctx, startDay: 0)
        makeStay(
            in: ctx, startDay: 0, category: .transit, hex: "T",
            trip: trip, durationHours: 24)
        makeStay(
            in: ctx, startDay: 2, category: .home, hex: "H",
            pingCount: 1, durationHours: 0.25)
        try ctx.save()

        #expect(await classifier.openTripClosureDue() == false)
    }

    @Test("closure is not due when there are no open trips")
    func openTripClosureNotDueWithoutOpenTrips() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.openTripClosureDue() == false)
    }

    @discardableResult
    private func makePing(
        in ctx: ModelContext, at timestamp: Date, source: DataSource
    ) -> LocationPing {
        let ping = LocationPing(
            timestamp: timestamp, latitude: 0, longitude: 0,
            horizontalAccuracy: 50, h3IndexRes6: "T", source: source)
        ctx.insert(ping)
        return ping
    }

    /// A transit stay starting an hour before now. Its linked pings are
    /// inserted in the listed order, each as (seconds before now, source).
    struct ProvisionalOpening: Sendable, CustomTestStringConvertible {
        let name: String
        let pings: [(secondsAgo: TimeInterval, source: DataSource)]
        let endSecondsAgo: TimeInterval
        let pingCount: Int
        let stamp: DataSource
        let assigned: Bool
        let due: Bool
        var testDescription: String { name }
    }

    nonisolated static let provisionalOpenings: [ProvisionalOpening] = [
        ProvisionalOpening(
            name: "a fresh corroborated unassigned transit stay makes provisional opening due",
            pings: [(3600, .liveSLC), (60, .liveSLC)], endSecondsAgo: 60,
            pingCount: 2, stamp: .liveSLC, assigned: false, due: true),
        // The clusterer's extension branch never restamps `Stay.source`, so
        // the arm must judge the newest linked ping, not the stay.
        ProvisionalOpening(
            name: "a photo-import stay extended by a live ping makes provisional opening due",
            pings: [(3600, .photoImport), (60, .liveSLC)], endSecondsAgo: 60,
            pingCount: 2, stamp: .photoImport, assigned: false, due: true),
        ProvisionalOpening(
            name: "a photo-import stay extended by a foreground-stream ping makes provisional opening due",
            pings: [(3600, .photoImport), (60, .foregroundStream)], endSecondsAgo: 60,
            pingCount: 2, stamp: .photoImport, assigned: false, due: true),
        ProvisionalOpening(
            name: "a stay whose newest ping is imported does not make provisional opening due",
            pings: [(3600, .liveSLC), (60, .photoImport)], endSecondsAgo: 60,
            pingCount: 2, stamp: .liveSLC, assigned: false, due: false),
        ProvisionalOpening(
            name: "a single-ping transit stay does not make provisional opening due",
            pings: [], endSecondsAgo: 60,
            pingCount: 1, stamp: .liveSLC, assigned: false, due: false),
        ProvisionalOpening(
            name: "a stale transit stay does not make provisional opening due",
            pings: [(3600, .liveSLC), (16 * 60, .liveSLC)], endSecondsAgo: 16 * 60,
            pingCount: 2, stamp: .liveSLC, assigned: false, due: false),
        ProvisionalOpening(
            name: "an assigned transit stay does not make provisional opening due",
            pings: [(3600, .liveSLC), (60, .liveSLC)], endSecondsAgo: 60,
            pingCount: 2, stamp: .liveSLC, assigned: true, due: false),
    ]

    @Test("provisional opening is due only for a fresh, corroborated, live, unassigned transit stay",
          arguments: provisionalOpenings)
    func provisionalOpenDue(row: ProvisionalOpening) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)
        let now = Date.now
        let trip = row.assigned ? Trip(startDate: now.addingTimeInterval(-3600)) : nil
        if let trip { ctx.insert(trip) }
        let pings = row.pings.map {
            makePing(in: ctx, at: now.addingTimeInterval(-$0.secondsAgo), source: $0.source)
        }
        let stay = makeStay(
            in: ctx, start: now.addingTimeInterval(-3600),
            end: now.addingTimeInterval(-row.endSecondsAgo), category: .transit,
            hex: "T", trip: trip, pingCount: row.pingCount, source: row.stamp)
        if !pings.isEmpty { stay.pingIDs = pings.map(\.id) }
        try ctx.save()

        #expect(await classifier.provisionalOpenDue() == row.due)
    }

    @Test("A fully-consistent store does NOT report an invariant violation (back half may skip)")
    func consistentStoreHoldsInvariant() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let trip = makeTrip(in: ctx, startDay: 0)
        // dest/transit stays are IN a trip; home/routine are NOT — the invariant.
        makeStay(in: ctx, startDay: 0, category: .destination, hex: "A", trip: trip)
        makeStay(in: ctx, startDay: 1, category: .transit, hex: "B", trip: trip)
        makeStay(in: ctx, startDay: 2, category: .home, hex: "H", trip: nil)
        makeStay(in: ctx, startDay: 3, category: .routine, hex: "R", trip: nil)
        try ctx.save()

        let violated = await classifier.assemblyInvariantViolatedForTesting()
        #expect(violated == false)
    }

    @Test("An unassigned destination stay (trip == nil) forces the back half to run")
    func unassignedDestinationViolates() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // A destination stay left with no trip — the residue of a merge/import
        // or a fresh cluster pass. Must NOT be skipped.
        makeStay(in: ctx, startDay: 0, category: .destination, hex: "A", trip: nil)
        try ctx.save()

        let violated = await classifier.assemblyInvariantViolatedForTesting()
        #expect(violated == true)
    }

    @Test("A home stay still attached to a trip (e.g. after a category override) forces a run")
    func misattachedHomeViolates() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let trip = makeTrip(in: ctx, startDay: 0)
        makeStay(in: ctx, startDay: 0, category: .destination, hex: "A", trip: trip)
        // User overrode a destination stay to `home` but it is still in the
        // trip — the stale state a naive gate would fail to repair.
        makeStay(in: ctx, startDay: 1, category: .home, hex: "H", trip: trip)
        try ctx.save()

        let violated = await classifier.assemblyInvariantViolatedForTesting()
        #expect(violated == true)
    }

    @Test("An empty store holds the invariant (nothing to assemble)")
    func emptyStoreHoldsInvariant() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let classifier = TripClassifier(modelContainer: container)
        let violated = await classifier.assemblyInvariantViolatedForTesting()
        #expect(violated == false)
    }
}
