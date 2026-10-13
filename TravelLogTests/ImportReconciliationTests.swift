//
//  ImportReconciliationTests.swift
//  TravelLogTests
//
//  Completed-trip import reconciliation: a late
//  historical import that creates stays inside or beside a completed trip's
//  home-free segment must regroup INTO that trip (identity preserved via the
//  most-shared-stays rule) instead of forming an overlapping
//  fragment. The detach predicate mirrors the grouping fold exactly, so the
//  result must equal what a full Reclassify All would produce for the
//  affected segment.
//
//  Pattern (same as TripAssemblyTests / OngoingTripReuseTests): seed the
//  "previous run's" state by hand via a plain context + save, then read
//  results ONLY through the actor's seams; assembleTrips doesn't save, so a
//  fresh ModelContext can't see its in-context changes.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
struct ImportReconciliationTests {

    private static let day: TimeInterval = 24 * 60 * 60

    private func date(day offset: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: offset * Self.day)
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

    /// Hand-builds a COMPLETED trip from the given stays (what a previous
    /// pipeline pass would have persisted after `closeTrip`).
    @discardableResult
    private func makeCompletedTrip(
        in ctx: ModelContext,
        stays: [Stay],
        userEdited: Bool = false,
        classifiedByAI: Bool = false
    ) -> Trip {
        let trip = Trip(startDate: stays.first!.startTime)
        trip.endDate = stays.last!.endTime
        trip.isComplete = true
        trip.userEdited = userEdited
        trip.classifiedByAI = classifiedByAI
        ctx.insert(trip)
        for (order, stay) in stays.enumerated() {
            stay.trip = trip
            stay.orderInTrip = order
        }
        return trip
    }

    // MARK: - Core fragmentation repair

    @Test("an imported stay inside a completed trip's span regroups into it; id preserved, no fragment")
    func midSpanImportJoinsCompletedTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        makeStay(in: ctx, startDay: 0, category: .home, hex: "H")
        let s1 = makeStay(in: ctx, startDay: 1, category: .destination, hex: "A")
        let s2 = makeStay(in: ctx, startDay: 5, category: .destination, hex: "B")
        let trip = makeCompletedTrip(in: ctx, stays: [s1, s2], classifiedByAI: true)
        makeStay(in: ctx, startDay: 6, category: .home, hex: "H")
        // The late import: a genuine June-3 destination >3 km from both
        // existing stays (pre-attach missed it; it's a fresh classified Stay).
        let imported = makeStay(in: ctx, startDay: 3, category: .destination, hex: "C")
        try ctx.save()

        _ = await classifier.assembleTrips()

        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.count == 1)
        #expect(trips.first?.id == trip.id)          // identity restored
        #expect(trips.first?.isComplete == true)     // home on day 6 still closes it
        let members = await classifier.tripStayIDsForTesting(trip.id)
        #expect(members == Set([s1.id, s2.id, imported.id]))
        // Provenance unions across passes: the FM-classified history
        // survives absorbing the (unclassified-this-pass) import stay.
        #expect(await classifier.classifiedByAIForTesting(trip.id) == true)
    }

    @Test("an imported stay after the trip's last stay but before the return home joins it")
    func adjacentBeforeReturnHomeJoins() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        makeStay(in: ctx, startDay: 0, category: .home, hex: "H")
        let s1 = makeStay(in: ctx, startDay: 1, category: .destination, hex: "A")
        let trip = makeCompletedTrip(in: ctx, stays: [s1])
        makeStay(in: ctx, startDay: 5, category: .home, hex: "H")
        // Imported stay on day 3: after the trip's last stay, but NO home
        // stay between them; the fold would have grouped it.
        let imported = makeStay(in: ctx, startDay: 3, category: .destination, hex: "B")
        try ctx.save()

        _ = await classifier.assembleTrips()

        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.count == 1)
        #expect(trips.first?.id == trip.id)
        #expect(trips.first?.isComplete == true)
        let members = await classifier.tripStayIDsForTesting(trip.id)
        #expect(members == Set([s1.id, imported.id]))
    }

    @Test("a stay after the return home is a separate journey; completed trip untouched")
    func separateJourneyLeavesCompletedTripAlone() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        makeStay(in: ctx, startDay: 0, category: .home, hex: "H")
        let s1 = makeStay(in: ctx, startDay: 1, category: .destination, hex: "A")
        let trip = makeCompletedTrip(in: ctx, stays: [s1])
        makeStay(in: ctx, startDay: 2, category: .home, hex: "H")
        // New stay AFTER the return home; the live-pass shape. The closeTrip
        // invariant (complete ⇒ home exists after the end) guarantees this
        // can never detach the completed trip.
        let fresh = makeStay(in: ctx, startDay: 3, category: .destination, hex: "B")
        try ctx.save()

        _ = await classifier.assembleTrips()

        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.count == 2)
        #expect(await classifier.tripStayIDsForTesting(trip.id) == Set([s1.id]))
        let freshTrip = trips.first { $0.id != trip.id }
        #expect(freshTrip != nil)
        if let freshTrip {
            #expect(await classifier.tripStayIDsForTesting(freshTrip.id) == Set([fresh.id]))
        }
    }

    @Test("a userEdited completed trip is never detached; the import fragment is the accepted residual")
    func userEditedTripIsExempt() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        makeStay(in: ctx, startDay: 0, category: .home, hex: "H")
        let s1 = makeStay(in: ctx, startDay: 1, category: .destination, hex: "A")
        let s2 = makeStay(in: ctx, startDay: 5, category: .destination, hex: "B")
        let trip = makeCompletedTrip(in: ctx, stays: [s1, s2], userEdited: true)
        makeStay(in: ctx, startDay: 6, category: .home, hex: "H")
        let imported = makeStay(in: ctx, startDay: 3, category: .destination, hex: "C")
        try ctx.save()

        _ = await classifier.assembleTrips()

        // The user's merge/split intent is sacred: the trip survives intact
        // and the import forms its own (overlapping) trip.
        #expect(await classifier.tripStayIDsForTesting(trip.id) == Set([s1.id, s2.id]))
        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.count == 2)
        let fragment = trips.first { $0.id != trip.id }
        if let fragment {
            #expect(await classifier.tripStayIDsForTesting(fragment.id) == Set([imported.id]))
        }
    }

    // MARK: - Fragment merging and splitting

    @Test("an import bridging two pre-fix fragments merges them; the earlier equal-size fragment keeps its id")
    func gapBridgeMergesFragments() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        makeStay(in: ctx, startDay: 0, category: .home, hex: "H")
        let s1 = makeStay(in: ctx, startDay: 1, category: .destination, hex: "A")
        let t1 = makeCompletedTrip(in: ctx, stays: [s1])
        // t2 is FM-classified: its provenance must survive losing the
        // id claim to t1 (pre-fix, the second snapshot
        // was skipped entirely once its only candidate was claimed, and
        // the merged trip silently downgraded to heuristic provenance).
        let s2 = makeStay(in: ctx, startDay: 5, category: .destination, hex: "B")
        let t2 = makeCompletedTrip(in: ctx, stays: [s2], classifiedByAI: true)
        makeStay(in: ctx, startDay: 6, category: .home, hex: "H")
        // No home between s1 and s2; t1/t2 are exactly the pre-fix
        // fragmentation shape. The new day-3 stay is adjacent to BOTH.
        let imported = makeStay(in: ctx, startDay: 3, category: .destination, hex: "C")
        try ctx.save()

        _ = await classifier.assembleTrips()

        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.count == 1)
        // Equal prior-stay counts (1 vs 1): snapshots claim in (count desc,
        // startDate asc, id) order, so the EARLIER fragment t1 claims the
        // merged trip; t2's id retires deterministically.
        #expect(trips.first?.id == t1.id)
        #expect(await classifier.tripStayIDsForTesting(t1.id) == Set([s1.id, s2.id, imported.id]))
        #expect(await classifier.tripStayIDsForTesting(t2.id) == nil)
        // …but t2's FM history rode along: any-FM → true on the merged trip.
        #expect(await classifier.classifiedByAIForTesting(t1.id) == true)
    }

    @Test("an imported mid-trip home stay splits the trip; the id follows the larger fragment (ties → later)")
    func importedHomeSplitsAndIdFollowsMostStays() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        makeStay(in: ctx, startDay: 0, category: .home, hex: "H")
        let s1 = makeStay(in: ctx, startDay: 1, category: .destination, hex: "A")
        let s2 = makeStay(in: ctx, startDay: 5, category: .destination, hex: "B")
        let trip = makeCompletedTrip(in: ctx, stays: [s1, s2])
        makeStay(in: ctx, startDay: 6, category: .home, hex: "H")
        // The import reveals the user actually went home on day 3 and then
        // visited somewhere new on day 3.5: the old single trip is wrong.
        makeStay(in: ctx, startDay: 3, category: .home, hex: "H")
        let imported = makeStay(in: ctx, startDay: 3.5, category: .destination, hex: "C")
        try ctx.save()

        _ = await classifier.assembleTrips()

        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.count == 2)
        // Fragments share 1 prior stay each (s1 | s2); tie breaks to the
        // LATER fragment, so the old id lands on
        // the {imported, s2} trip.
        let members = await classifier.tripStayIDsForTesting(trip.id)
        #expect(members == Set([imported.id, s2.id]))
        let other = trips.first { $0.id != trip.id }
        if let other {
            #expect(await classifier.tripStayIDsForTesting(other.id) == Set([s1.id]))
        }
    }

    // MARK: - Ongoing-row interplay

    @Test("reconciliation coexists with the ongoing-row reuse: both identities survive one pass")
    func ongoingRowAndReconciliationCoexist() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        makeStay(in: ctx, startDay: 0, category: .home, hex: "H")
        let s1 = makeStay(in: ctx, startDay: 1, category: .destination, hex: "A")
        let s2 = makeStay(in: ctx, startDay: 5, category: .destination, hex: "B")
        let completed = makeCompletedTrip(in: ctx, stays: [s1, s2])
        makeStay(in: ctx, startDay: 6, category: .home, hex: "H")
        // The currently-ongoing journey (incomplete row, day 10).
        let s3 = makeStay(in: ctx, startDay: 10, category: .destination, hex: "D")
        let ongoing = Trip(startDate: s3.startTime)
        ctx.insert(ongoing)
        s3.trip = ongoing
        s3.orderInTrip = 0
        // The late import lands inside the COMPLETED trip's span.
        let imported = makeStay(in: ctx, startDay: 3, category: .destination, hex: "C")
        try ctx.save()

        _ = await classifier.assembleTrips()

        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.count == 2)
        #expect(await classifier.tripStayIDsForTesting(completed.id) == Set([s1.id, s2.id, imported.id]))
        // The ongoing row keeps ITS identity too (reuse binding
        // is unaffected by the reconciliation pool extension).
        #expect(await classifier.tripStayIDsForTesting(ongoing.id) == Set([s3.id]))
        #expect(trips.first { $0.id == ongoing.id }?.isComplete == false)
    }

    @Test("a bridge-merged completed trip's identity claims the reused row when its stays dominate")
    func dominantCompletedTripClaimsMergedOngoingRow() async throws {
        // An import that bridges the completed
        // trip's closing home boundary folds the completed trip AND the
        // ongoing journey into ONE group bound to the reused ongoing row.
        // The old unconditional never-claim guard silently retired the
        // completed trip's id; orphaning its favorites and hidden/pinned
        // photos. Identity follows the dominant constituent.
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        makeStay(in: ctx, startDay: 0, category: .home, hex: "H")
        // Completed trip with THREE stays (dominant side).
        let s1 = makeStay(in: ctx, startDay: 1, category: .destination, hex: "A")
        let s2 = makeStay(in: ctx, startDay: 2, category: .destination, hex: "B")
        let s3 = makeStay(in: ctx, startDay: 3, category: .destination, hex: "C")
        let completed = makeCompletedTrip(in: ctx, stays: [s1, s2, s3])
        // NO qualifying home stay after it; the "homecoming" that closed it
        // was a zero-dwell phantom, or the import below erased the gap.
        // Ongoing journey: ONE stay in a fresh row.
        let s5 = makeStay(in: ctx, startDay: 6, category: .destination, hex: "E")
        let ongoing = Trip(startDate: s5.startTime)
        ctx.insert(ongoing)
        s5.trip = ongoing
        s5.orderInTrip = 0
        // The late import lands between them (home-free adjacency →
        // reconciliation detaches the completed trip).
        let imported = makeStay(in: ctx, startDay: 4.5, category: .destination, hex: "D")
        try ctx.save()

        _ = await classifier.assembleTrips()

        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.count == 1)
        // The merged journey carries the COMPLETED trip's identity (3 prior
        // stays vs the ongoing row's 1); its curation survives.
        #expect(await classifier.tripStayIDsForTesting(completed.id)
                == Set([s1.id, s2.id, s3.id, imported.id, s5.id]))
        #expect(trips.first?.id == completed.id)
        #expect(trips.first?.isComplete == false)
    }

    @Test("regrouped membership change drops the carried title; it must regenerate against the fuller trip")
    func titleRegeneratesAfterReconciliation() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        makeStay(in: ctx, startDay: 42, category: .home, hex: "H")
        let s1 = makeStay(in: ctx, startDay: 43, category: .destination, hex: "A")
        let trip = makeCompletedTrip(in: ctx, stays: [s1])
        trip.aiGeneratedTitle = "Athens Getaway"
        makeStay(in: ctx, startDay: 47, category: .home, hex: "H")
        makeStay(in: ctx, startDay: 45, category: .destination, hex: "B")
        try ctx.save()

        _ = await classifier.assembleTrips()

        // Stay set changed (absorbed the import), so the exact-set carry
        // cannot fire: the stale one-destination title is dropped and Stage
        // 5 will regenerate against the two-destination trip.
        let fields = await classifier.aiTitleFieldsForTesting(trip.id)
        #expect(fields != nil)
        #expect(fields?.title == nil)
    }
}
