//
//  ReclassifyIdentityRestoreTests.swift
//  TravelLogTests
//
//  Pins `TripClassifier.identityClaims`, Reclassify All's rule for keeping
//  a trip's id by its largest surviving overlap of stays.
//
//  Why: a trip's dates are purely membership-derived, so a boundary-date
//  shift IS a membership shift, and a change of home geometry such as the
//  home-shape cutover can shift trip boundaries. The old exact-set rule
//  restored ids only on identical stay sets, so any trip whose membership
//  changed would have re-minted its id on Reclassify All, orphaning favorites
//  (PinnedTripsStorage) and resurrecting hidden photos (both key on bare
//  Trip.id UUIDs). The `gainedOneStay` test catches the old exact-set rule.
//

import Foundation
import Testing
@testable import TravelLog

struct ReclassifyIdentityRestoreTests {

    private func uuid(_ n: UInt8) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", Int(n)))!
    }

    private func date(day offset: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: offset * 24 * 3600)
    }

    @Test("an identical stay set keeps its id (the old rule's case still holds)")
    func exactSetStillClaims() {
        let old = uuid(1), rebuilt = uuid(2)
        let stays: Set<UUID> = [uuid(10), uuid(11)]
        let claims = TripClassifier.identityClaims(
            snapshots: [(id: old, stayIDs: stays, startDate: date(day: 0))],
            rebuilt: [(id: rebuilt, stayIDs: stays, startDate: date(day: 0))])
        #expect(claims[rebuilt] == old)
    }

    @Test("a rebuilt trip that GAINED one stay keeps its id, fails under the exact-set rule")
    func gainedOneStay() {
        let old = uuid(1), rebuilt = uuid(2)
        let claims = TripClassifier.identityClaims(
            snapshots: [(id: old, stayIDs: [uuid(10), uuid(11)], startDate: date(day: 0))],
            rebuilt: [(id: rebuilt, stayIDs: [uuid(10), uuid(11), uuid(12)],
                       startDate: date(day: 0))])
        #expect(claims[rebuilt] == old,
                "a boundary shift is a membership shift; identity must survive it")
    }

    @Test("dominance wins regardless of snapshot date order")
    func mergeFollowsDominanceRegardlessOfOrder() {
        // Claiming is greedy and
        // first-come, and the first port ordered snapshots by (startDate, id)
        // alone, so a SMALL early trip that merged with a BIG later one
        // claimed the merged row first, retiring the big trip's id (the one
        // carrying favorites/hidden photos). Ordering by stay count
        // DESC first; this fixture puts the small trip EARLIER to prove the
        // count key decides.
        let smallEarly = uuid(1), bigLate = uuid(2), merged = uuid(3)
        let claims = TripClassifier.identityClaims(
            snapshots: [
                (id: smallEarly, stayIDs: [uuid(10)], startDate: date(day: 0)),
                (id: bigLate, stayIDs: [uuid(11), uuid(12), uuid(13)], startDate: date(day: 5)),
            ],
            rebuilt: [(id: merged, stayIDs: [uuid(10), uuid(11), uuid(12), uuid(13)],
                       startDate: date(day: 0))])
        #expect(claims[merged] == bigLate)
        #expect(claims.values.contains(smallEarly) == false)
    }

    @Test("a merge keeps the dominant constituent's id; the loser's id dies")
    func mergeFollowsDominance() {
        let bigOld = uuid(1), smallOld = uuid(2), merged = uuid(3)
        let claims = TripClassifier.identityClaims(
            snapshots: [
                (id: bigOld, stayIDs: [uuid(10), uuid(11)], startDate: date(day: 0)),
                (id: smallOld, stayIDs: [uuid(12)], startDate: date(day: 5)),
            ],
            rebuilt: [(id: merged, stayIDs: [uuid(10), uuid(11), uuid(12)],
                       startDate: date(day: 0))])
        #expect(claims[merged] == bigOld)
        #expect(claims.values.contains(smallOld) == false,
                "the absorbed trip no longer exists; its id must not hijack anything")
    }

    @Test("a split hands the id to the fragment sharing the most stays")
    func splitFollowsDominance() {
        let old = uuid(1), bigFragment = uuid(2), smallFragment = uuid(3)
        let claims = TripClassifier.identityClaims(
            snapshots: [(id: old,
                         stayIDs: [uuid(10), uuid(11), uuid(12), uuid(13)],
                         startDate: date(day: 0))],
            rebuilt: [
                (id: bigFragment, stayIDs: [uuid(10), uuid(11), uuid(12)],
                 startDate: date(day: 0)),
                (id: smallFragment, stayIDs: [uuid(13)], startDate: date(day: 3)),
            ])
        #expect(claims[bigFragment] == old)
        #expect(claims[smallFragment] == nil)
    }

    @Test("a snapshot with no surviving stays claims nothing")
    func vanishedTripClaimsNothing() {
        let claims = TripClassifier.identityClaims(
            snapshots: [(id: uuid(1), stayIDs: [uuid(10)], startDate: date(day: 0))],
            rebuilt: [(id: uuid(2), stayIDs: [uuid(20)], startDate: date(day: 0))])
        #expect(claims.isEmpty)
    }

    @Test("equal overlap ties break to later startDate, then smaller id")
    func deterministicTieBreak() {
        let old = uuid(1)
        let earlier = uuid(2), later = uuid(3)
        // Both rebuilt trips share exactly one stay with the snapshot.
        let claims = TripClassifier.identityClaims(
            snapshots: [(id: old, stayIDs: [uuid(10), uuid(11)], startDate: date(day: 0))],
            rebuilt: [
                (id: earlier, stayIDs: [uuid(10)], startDate: date(day: 0)),
                (id: later, stayIDs: [uuid(11)], startDate: date(day: 2)),
            ])
        #expect(claims[later] == old)
        #expect(claims[earlier] == nil)
    }
}
