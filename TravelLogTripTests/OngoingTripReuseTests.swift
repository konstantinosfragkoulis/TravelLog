//
//  OngoingTripReuseTests.swift
//  TravelLogTests
//
//  In-place reuse of the ongoing trip's row across assembleTrips passes
//  prevents deleting the model held by an open
//  TripDetailView on every pipeline run. The row, UUID and
//  all, must survive re-assembly; everything else about assembly
//  semantics is unchanged (TripAssemblyTests pins those).
//
//  Pattern (same as TripAssemblyTests): seed the "previous run's" state by
//  hand via a plain context + save, then read results ONLY through the
//  actor's seams, assembleTrips doesn't save, so a fresh ModelContext
//  can't see its in-context changes.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor @Suite(IsolatedLineageDefaults())
struct OngoingTripReuseTests {

    private static let day: TimeInterval = 24 * 60 * 60

    private func date(day offset: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: -3_628_800 + offset * Self.day)
    }

    @discardableResult
    private func makeStay(
        in ctx: ModelContext,
        startDay: Double,
        durationHours: Double = 6,
        category: StayCategory,
        hex: String
    ) -> Stay {
        let start = date(day: startDay)
        let stay = Stay(
            startTime: start,
            endTime: start.addingTimeInterval(durationHours * 3600),
            centroidLatitude: 0, centroidLongitude: 0,
            h3IndexRes6: hex,
            // 2, not 1: these helpers build multi-hour stays, which in
            // production always hold at least an arrival and a later fix.
            // `isQualifyingHomeBoundary` rejects a DEFINITIVELY single-ping
            // live-SLC home stay because its dwell is synthesized by the
            // clusterer's midpoint extension rather than measured.
            pingCount: 2,
            distanceFromHomeKm: 0, pingIDs: []
        )
        stay.category = category
        ctx.insert(stay)
        return stay
    }

    /// Hand-builds "the previous pipeline run's" open trip holding `stays`.
    private func makeOpenTrip(in ctx: ModelContext, stays: [Stay], startDay: Double) -> Trip {
        let trip = Trip(startDate: date(day: startDay))
        ctx.insert(trip)
        for (order, stay) in stays.enumerated() {
            stay.trip = trip
            stay.orderInTrip = order
        }
        return trip
    }

    @Test("the ongoing trip keeps its UUID when a new stay accretes mid-trip")
    func ongoingTripIdentityIsStable() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let s0 = makeStay(in: ctx, startDay: 0, category: .destination, hex: "A")
        let openTrip = makeOpenTrip(in: ctx, stays: [s0], startDay: 0)
        // The mid-trip accretion case: a NEW unassigned stay arrives.
        makeStay(in: ctx, startDay: 1, category: .destination, hex: "B")
        try ctx.save()

        _ = await classifier.assembleTrips()

        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.count == 1)
        #expect(trips.first?.id == openTrip.id)   // Same row, no churn.
        #expect(trips.first?.isComplete == false)
        let orders01: [Int?] = [0, 1]
        #expect(trips.first?.orders == orders01)
    }

    @Test("closing the trip (home stay appeared) reuses the same row too")
    func closingReusesTheRow() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let s0 = makeStay(in: ctx, startDay: 0, category: .destination, hex: "A")
        let openTrip = makeOpenTrip(in: ctx, stays: [s0], startDay: 0)
        openTrip.aiGeneratedTitle = "Aegina in Progress"
        ctx.insert(TripTitleVariant(
            languageTag: "de", title: "Aegina unterwegs",
            sourceTitle: "Aegina in Progress", trip: openTrip))
        makeStay(in: ctx, startDay: 2, category: .home, hex: "H")
        try ctx.save()

        _ = await classifier.assembleTrips()

        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.count == 1)
        #expect(trips.first?.id == openTrip.id)
        #expect(trips.first?.isComplete == true)
        #expect(trips.first?.hasEndDate == true)
        let fields = try #require(await classifier.aiTitleFieldsForTesting(openTrip.id))
        #expect(fields.title == nil)
        #expect(fields.localizedCount == 0)
    }

    @Test("split into two: the surviving row follows its OWN prior stays, not the ongoing tail")
    func splitKeepsIdentityWithPriorStays() async throws {
        // When the previously-open trip's stays split
        // into two journeys in one pass (user came home and left again
        // between runs), "the same trip" is the fragment holding the row's
        // prior stays, favorites and an open detail view are attached to
        // THAT journey. The new later journey is a new trip and gets a
        // fresh id (it becomes the reusable row on the NEXT pass).
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // Previous run's open trip (stay A)…
        let s0 = makeStay(in: ctx, startDay: 0, category: .destination, hex: "A")
        let openTrip = makeOpenTrip(in: ctx, stays: [s0], startDay: 0)
        // …then the user went home and left again: home gap + new stay B.
        makeStay(in: ctx, startDay: 2, category: .home, hex: "H")
        makeStay(in: ctx, startDay: 4, category: .destination, hex: "B")
        try ctx.save()

        _ = await classifier.assembleTrips()

        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.count == 2)
        // Sorted by startDate: [A-trip (closed, keeps the old identity),
        // B-trip (ongoing, brand-new journey → fresh id)].
        #expect(trips.first?.isComplete == true)
        #expect(trips.first?.id == openTrip.id)
        #expect(trips.last?.isComplete == false)
        #expect(trips.last?.id != openTrip.id)
    }

    @Test("split with the majority of prior stays in the later fragment keeps identity there")
    func splitFollowsMajorityIntoLaterFragment() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // Previous run's open trip held A, B, C. A home stay slotting in
        // between A and B (late sync) now splits it [A] | [B, C], the
        // majority fragment keeps the row.
        let s0 = makeStay(in: ctx, startDay: 0, category: .destination, hex: "A")
        let s1 = makeStay(in: ctx, startDay: 4, category: .destination, hex: "B")
        let s2 = makeStay(in: ctx, startDay: 5, category: .destination, hex: "C")
        let openTrip = makeOpenTrip(in: ctx, stays: [s0, s1, s2], startDay: 0)
        makeStay(in: ctx, startDay: 2, category: .home, hex: "H")
        try ctx.save()

        _ = await classifier.assembleTrips()

        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.count == 2)
        #expect(trips.first?.isComplete == true)
        #expect(trips.first?.id != openTrip.id)
        #expect(trips.last?.isComplete == false)
        #expect(trips.last?.id == openTrip.id)
    }

    @Test("a committed split keeps the stored narrative on the fragment that keeps the row, and the other fragment starts without one")
    func splitKeepsStoredNarrativeOnTheReusedRow() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let s0 = makeStay(in: ctx, startDay: 0, category: .destination, hex: "A")
        let s1 = makeStay(in: ctx, startDay: 4, category: .destination, hex: "B")
        let s2 = makeStay(in: ctx, startDay: 5, category: .destination, hex: "C")
        let openTrip = makeOpenTrip(in: ctx, stays: [s0, s1, s2], startDay: 0)
        openTrip.aiGeneratedSummary = "Three islands in one go."
        makeStay(in: ctx, startDay: 2, category: .home, hex: "H")
        try ctx.save()

        _ = await classifier.classifyAndAssembleTripsWithGates(
            maxStaysPerCall: nil, gate: PipelineGate(forTesting: ()))

        let trips = try ModelContext(container).fetch(FetchDescriptor<Trip>())
        #expect(trips.count == 2)
        let reused = try #require(trips.first { $0.id == openTrip.id })
        #expect(Set((reused.stays ?? []).map(\.id)) == [s1.id, s2.id])
        #expect(reused.aiGeneratedSummary == "Three islands in one go.")
        let fragment = try #require(trips.first { $0.id != openTrip.id })
        #expect(fragment.aiGeneratedSummary == nil)
    }

    @Test("zero prior-stay overlap falls back to the LAST (ongoing) group")
    func zeroOverlapFallsBackToLastGroup() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // The surviving row holds NO stays (all previously detached /
        // empty open trip), no fragment can claim it by membership, so it
        // follows the ongoing tail.
        let openTrip = makeOpenTrip(in: ctx, stays: [], startDay: 0)
        makeStay(in: ctx, startDay: 0, category: .destination, hex: "A")
        makeStay(in: ctx, startDay: 2, category: .home, hex: "H")
        makeStay(in: ctx, startDay: 4, category: .destination, hex: "B")
        try ctx.save()

        _ = await classifier.assembleTrips()

        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.count == 2)
        #expect(trips.first?.isComplete == true)
        #expect(trips.first?.id != openTrip.id)
        #expect(trips.last?.isComplete == false)
        #expect(trips.last?.id == openTrip.id)
    }

    @Test("a reused row with an unchanged stay-set keeps its AI title")
    func reusedRowKeepsTitleWhenStaysUnchanged() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let s0 = makeStay(in: ctx, startDay: 0, category: .destination, hex: "A")
        let openTrip = makeOpenTrip(in: ctx, stays: [s0], startDay: 0)
        openTrip.aiGeneratedTitle = "Aegina"
        try ctx.save()

        _ = await classifier.assembleTrips()

        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.count == 1)
        #expect(trips.first?.id == openTrip.id)
        let fields = try #require(await classifier.aiTitleFieldsForTesting(openTrip.id))
        #expect(fields.title == "Aegina")   // carry-forward parity
    }

    @Test("when no trip-class stays remain, the surviving row is deleted, not orphaned")
    func orphanRowIsDeletedWhenNothingRemains() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // The open trip's only stay was reclassified to .routine, no
        // destination/transit stays exist anywhere.
        let s0 = makeStay(in: ctx, startDay: 0, category: .routine, hex: "A")
        _ = makeOpenTrip(in: ctx, stays: [s0], startDay: 0)
        try ctx.save()

        _ = await classifier.assembleTrips()

        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.isEmpty)
    }
}
