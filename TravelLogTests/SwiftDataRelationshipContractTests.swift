//
//  SwiftDataRelationshipContractTests.swift
//  TravelLogTests
//
//  Checks when SwiftData realizes a to-many inverse relationship.
//  Assignment updates the inverse before save; pending deletion does not
//  remove a stay from `trip.stays`. Repair paths must explicitly detach a
//  stay before deleting it and recomputing the trip's dates, as covered in
//  `DiscardTeardownRepairTests`. These tests also detect changes in that
//  behavior across SwiftData releases.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
struct SwiftDataRelationshipContractTests {

    private static let base = Date(timeIntervalSinceReferenceDate: 760 * 86_400)

    private func makeStay(in ctx: ModelContext, dayOffset: Double) -> Stay {
        let start = Self.base.addingTimeInterval(dayOffset * 86_400)
        let stay = Stay(
            startTime: start, endTime: start.addingTimeInterval(3600),
            centroidLatitude: 37.9838, centroidLongitude: 23.7275,
            h3IndexRes6: "8a2a1072b59ffff", pingCount: 2,
            distanceFromHomeKm: 30, pingIDs: []
        )
        stay.category = .destination
        ctx.insert(stay)
        return stay
    }

    /// ASSIGNING a stay to a trip: is the inverse array updated immediately?
    ///
    /// `TripsListView.mergeTrips` depends on this — it re-assigns the source
    /// trip's stays and then reads `target.stays` to renumber `orderInTrip`
    /// and to `recomputeSummary()`, all before any save.
    @Test("assigning stay.trip realizes the inverse array before save")
    func assignmentIsRealizedPreSave() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let target = Trip(startDate: Self.base)
        ctx.insert(target)
        let existing = makeStay(in: ctx, dayOffset: 0)
        existing.trip = target
        try ctx.save()

        let absorbed = makeStay(in: ctx, dayOffset: 1)
        absorbed.trip = target
        // NO save between the assignment and the read — this is the merge path.
        #expect((target.stays ?? []).count == 2)
    }

    /// DELETING a stay: is it nullified out of the inverse array immediately?
    ///
    /// This is the one that was assumed and is FALSE. Photo-discard and the
    /// ping deduplicator both delete stays and then repair the trip's dates
    /// from `trip.orderedStays` in the same unit, so both must clear
    /// `stay.trip` explicitly first — which they now do.
    @Test("deleting a stay does NOT remove it from the inverse array before save")
    func deleteIsNotNullifiedPreSave() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let trip = Trip(startDate: Self.base)
        ctx.insert(trip)
        let keep = makeStay(in: ctx, dayOffset: 0)
        let doomed = makeStay(in: ctx, dayOffset: 1)
        keep.trip = trip
        doomed.trip = trip
        try ctx.save()

        ctx.delete(doomed)

        // The pending delete is STILL in the relationship array. If this ever
        // starts failing, SwiftData has changed and the explicit detaches in
        // PhotoImportService / PhotoImportPingDeduplicator became redundant
        // (harmless, but the comments there should be updated).
        #expect((trip.stays ?? []).count == 2)

        // …and the explicit detach is what actually removes it.
        let other = makeStay(in: ctx, dayOffset: 2)
        other.trip = trip
        other.trip = nil
        #expect(!(trip.stays ?? []).contains { $0.id == other.id })
    }

    /// The pattern every repair site must therefore use.
    @Test("detach-then-delete leaves the trip's stays correct before save")
    func detachThenDeleteIsCorrect() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let trip = Trip(startDate: Self.base)
        ctx.insert(trip)
        let keep = makeStay(in: ctx, dayOffset: 0)
        let doomed = makeStay(in: ctx, dayOffset: 1)
        keep.trip = trip
        doomed.trip = trip
        try ctx.save()

        doomed.trip = nil
        ctx.delete(doomed)

        let remaining = trip.orderedStays
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == keep.id)
    }

    /// Healing's trip read and the open-trip closure check prefetch the
    /// trips' stays. A prefetch must read what faulting them one by one reads:
    /// the same rows in the same relationship order (exact UUID twins tie in
    /// `orderedStays`, so that order picks the last stay), the same values,
    /// unsaved attribute edits, membership moves and inserts included.
    @Test("prefetching trips' stays reads what faulting them reads, in the same order, unsaved edits included")
    func staysPrefetchMatchesFaulting() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let writer = ModelContext(container)
        var trips: [Trip] = []
        var stayIDs: [[UUID]] = []
        var rows: [(Stay, String)] = []
        for t in 0..<3 {
            let trip = Trip(startDate: Self.base.addingTimeInterval(Double(t * 10) * 86_400))
            writer.insert(trip)
            trips.append(trip)
            var ids: [UUID] = []
            for s in 0..<4 {
                let stay = makeStay(in: writer, dayOffset: Double(t * 10 + s))
                stay.trip = trip
                stay.orderInTrip = s
                ids.append(stay.id)
                rows.append((stay, "t\(t)s\(s)"))
            }
            stayIDs.append(ids)
        }
        // Exact UUID twins: trip 0's first stay, and trip 1's last (same id,
        // order and start; ends 200 s and 400 s after the start).
        let firstTwin = makeStay(in: writer, dayOffset: 0)
        firstTwin.id = stayIDs[0][0]
        firstTwin.orderInTrip = 0
        firstTwin.endTime = firstTwin.endTime.addingTimeInterval(600)
        firstTwin.trip = trips[0]
        rows.append((firstTwin, "t0twin"))
        let lastStart = Self.base.addingTimeInterval(14 * 86_400)
        let lastID = UUID()
        for (end, label) in [(200.0, "t1lastA"), (400.0, "t1lastB")] {
            let stay = makeStay(in: writer, dayOffset: 14)
            stay.id = lastID
            stay.startTime = lastStart
            stay.endTime = lastStart.addingTimeInterval(end)
            stay.orderInTrip = 4
            stay.trip = trips[1]
            rows.append((stay, label))
        }
        let tripIDs = trips.map(\.id)
        try writer.save()
        var labels: [PersistentIdentifier: String] = [:]
        for (stay, label) in rows { labels[stay.persistentModelID] = label }
        // A qualifying home starting between the twins' ends closes trip 1
        // only when the 200 s twin is the last stay.
        let homeStart = lastStart.addingTimeInterval(300)

        func read(prefetch: Bool) throws -> PrefetchRead {
            let ctx = ModelContext(container)
            func stay(_ id: UUID) throws -> Stay {
                try #require(try ctx.fetch(FetchDescriptor<Stay>(predicate: #Predicate { $0.id == id })).first)
            }
            func trip(_ id: UUID) throws -> Trip {
                try #require(try ctx.fetch(FetchDescriptor<Trip>(predicate: #Predicate { $0.id == id })).first)
            }
            // The same unsaved edits in each context, before its trip read.
            let extended = try stay(stayIDs[0][2])
            extended.endTime = extended.endTime.addingTimeInterval(7200)
            let moved = try stay(stayIDs[1][1])
            moved.trip = try trip(tripIDs[0])
            moved.orderInTrip = 9
            let homed = try stay(stayIDs[2][3])
            homed.category = .home
            let inserted = makeStay(in: ctx, dayOffset: 25)
            inserted.id = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
            inserted.trip = try trip(tripIDs[2])
            inserted.orderInTrip = 5

            var descriptor = FetchDescriptor<Trip>()
            if prefetch { descriptor.relationshipKeyPathsForPrefetching = [\.stays] }
            var result = PrefetchRead()
            for fetched in try ctx.fetch(descriptor).sorted(by: { $0.startDate < $1.startDate }) {
                let label = { (stay: Stay) in labels[stay.persistentModelID] ?? "new" }
                result.order.append((fetched.stays ?? []).map(label))
                let ordered = fetched.orderedStays
                result.ordered.append(ordered.map(label))
                result.content.append((fetched.stays ?? []).map {
                    "\($0.id)|\($0.orderInTrip ?? -1)|\($0.startTime.timeIntervalSinceReferenceDate)|"
                        + "\($0.endTime.timeIntervalSinceReferenceDate)|\($0.categoryRaw)"
                }.sorted())
                // closeStaleOpenTrips' decision and the end date it would stamp.
                let last = ordered.last
                let closes = last.map { homeStart >= $0.endTime } ?? false
                result.closes.append(closes)
                result.endDates.append(closes ? last?.endTime : nil)
            }
            return result
        }
        let faulted = try read(prefetch: false)
        #expect(faulted.content.map(\.count) == [6, 5, 5])
        #expect(faulted.ordered[1].suffix(2).allSatisfy { $0.hasPrefix("t1last") })
        let prefetched = try read(prefetch: true)
        #expect(prefetched.order == faulted.order)
        #expect(prefetched.ordered == faulted.ordered)
        #expect(prefetched.content == faulted.content)
        #expect(prefetched.closes == faulted.closes)
        #expect(prefetched.endDates == faulted.endDates)
    }
}

/// One context's read in `staysPrefetchMatchesFaulting`. At file scope: a
/// type declared inside the test function makes `try #require` in its nested
/// helpers warn "no calls to throwing functions occur within 'try'".
private struct PrefetchRead: Equatable {
    var order: [[String]] = []      // physical rows, relationship order
    var ordered: [[String]] = []    // physical rows, orderedStays
    var content: [[String]] = []    // values, sorted
    var closes: [Bool] = []
    var endDates: [Date?] = []
}
