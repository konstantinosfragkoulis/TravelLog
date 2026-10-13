//
//  HexVisitDeduplicatorTests.swift
//  TravelLogTests
//
//  CloudKit-convergence deduplicator for HexVisit. Pins the deterministic
//  survivor selection (min by the IMMUTABLE id.uuidString; keying it on the
//  mutable firstVisited allowed a cross-device delete-war), the min-merge that
//  keeps the earliest firstVisited on whichever row survives, the independent
//  country/ISO absorption, the idempotent MAX merge of visitCount /
//  lastVisited (never a sum), the min-merge of firstVisited, nil-only backfill
//  of locality/country+iso, the shared-id skip guard (avoids converge-to-zero),
//  and order-independence + run-twice idempotence (the properties that make
//  two-device CloudKit convergence safe). Only a minted, table-unique
//  id may decide a deletion; two-replica oracles pin that no cell reaches zero.
//  Live multi-device sync is out of scope.
//
//  `@MainActor` because the app target compiles with MainActor-by-default
//  isolation, which makes `@Model` types (HexVisit) MainActor-isolated.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct HexVisitDeduplicatorTests {

    // MARK: - Fixtures

    /// UTC noon date; stable across timezones so the (firstVisited, lastVisited)
    /// orderings the survivor rule depends on never flip under DST/midnight skew.
    private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    /// Build a HexVisit. The init only takes h3Index/firstVisited/centers
    /// (lastVisited defaults to firstVisited, visitCount to 1); everything else
    /// is set by property assignment.
    private func makeHex(
        _ h3: String,
        first: Date,
        last: Date,
        count: Int,
        locality: String? = nil,
        country: String? = nil,
        iso: String? = nil,
        id: UUID? = nil
    ) -> HexVisit {
        let hex = HexVisit(
            h3Index: h3,
            firstVisited: first,
            centerLatitude: 37.98,
            centerLongitude: 23.72
        )
        hex.lastVisited = last
        hex.visitCount = count
        hex.locality = locality
        hex.country = country
        hex.isoCountryCode = iso
        if let id { hex.id = id }
        return hex
    }

    /// Re-fetch all HexVisit rows through a FRESH context so we observe what the
    /// deduplicator committed to the shared store (not the seeding graph).
    private func fetchAll(_ container: ModelContainer) throws -> [HexVisit] {
        let ctx = ModelContext(container)
        return try ctx.fetch(FetchDescriptor<HexVisit>())
    }

    // MARK: - No-op / guard paths

    @Test("empty store → deduplicateAll is a no-op and the store stays empty (count>1 guard)")
    func emptyStoreIsNoOp() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        await HexVisitDeduplicator.deduplicateAll(modelContainer: container)
        #expect(try fetchAll(container).isEmpty)
    }

    @Test("single row survives unchanged (count>1 guard skips merging)")
    func singleRowUntouched() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let hex = makeHex("86aaaaaaa", first: utc(2026, 7, 23), last: utc(2026, 7, 27), count: 7)
        ctx.insert(hex)
        try ctx.save()

        await HexVisitDeduplicator.deduplicateAll(modelContainer: container)

        let rows = try fetchAll(container)
        #expect(rows.count == 1)
        let survivor = try #require(rows.first)
        #expect(survivor.visitCount == 7)
        #expect(survivor.firstVisited == utc(2026, 7, 23))
        #expect(survivor.lastVisited == utc(2026, 7, 27))
    }

    @Test("three distinct h3 indices never merge; all three survive")
    func distinctH3IndicesNeverMerge() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        ctx.insert(makeHex("86aaa1", first: utc(2026, 7, 23), last: utc(2026, 7, 23), count: 1))
        ctx.insert(makeHex("86aaa2", first: utc(2026, 7, 24), last: utc(2026, 7, 24), count: 1))
        ctx.insert(makeHex("86aaa3", first: utc(2026, 7, 25), last: utc(2026, 7, 25), count: 1))
        try ctx.save()

        await HexVisitDeduplicator.deduplicateAll(modelContainer: container)

        #expect(try fetchAll(container).count == 3)
    }

    // MARK: - Survivor selection

    /// This used to assert the
    /// survivor was the row with the EARLIEST `firstVisited`. That keyed
    /// cross-device convergence on a MUTABLE field; four one-device paths
    /// rewrite `firstVisited` before it propagates; so two devices could
    /// order the group differently, each delete the row the other kept, and
    /// both deletions would sync, erasing the cell permanently.
    ///
    /// The survivor is now keyed on the immutable `id`. What must be preserved
    /// is the DATA, not which row object carries it: the surviving row still
    /// reports the earliest `firstVisited`, which is what every consumer reads.
    @Test("survivor keeps the EARLIEST firstVisited and is chosen by immutable id")
    func survivorKeepsEarliestFirstVisitedAndIsIdKeyed() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let early = makeHex("86min", first: utc(2026, 7, 23), last: utc(2026, 7, 24), count: 1)
        let late = makeHex("86min", first: utc(2026, 12, 21), last: utc(2026, 12, 22), count: 1)
        // Force the later-firstVisited row to survive, so the two rules disagree.
        early.id = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        late.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        ctx.insert(early)
        ctx.insert(late)
        let expectedSurvivorID = min(early.id.uuidString, late.id.uuidString)
        try ctx.save()

        await HexVisitDeduplicator.deduplicateAll(modelContainer: container)

        let rows = try fetchAll(container).filter { $0.h3Index == "86min" }
        #expect(rows.count == 1)
        let survivor = try #require(rows.first)
        #expect(survivor.id.uuidString == expectedSurvivorID)
        // The earliest window is absorbed regardless of which row survived.
        #expect(survivor.firstVisited == utc(2026, 7, 23))
        #expect(survivor.lastVisited == utc(2026, 12, 22))
    }

    // MARK: - Field merges

    @Test("survivor.firstVisited == min firstVisited across the whole group")
    func firstVisitedMergesToMinAcrossGroup() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // The later row survives, so the minimum must come from the donor.
        ctx.insert(makeHex("86fmin", first: utc(2026, 8, 23), last: utc(2026, 8, 23), count: 1, id: Self.mintedHigh))
        ctx.insert(makeHex("86fmin", first: utc(2026, 11, 20), last: utc(2026, 11, 20), count: 1, id: Self.mintedLow))
        try ctx.save()

        await HexVisitDeduplicator.deduplicateAll(modelContainer: container)

        let rows = try fetchAll(container).filter { $0.h3Index == "86fmin" }
        #expect(rows.count == 1)
        let survivor = try #require(rows.first)
        #expect(survivor.id == Self.mintedLow)
        #expect(survivor.firstVisited == utc(2026, 8, 23))
    }

    @Test("survivor.lastVisited == max lastVisited, even when the max belongs to the loser")
    func lastVisitedMergesToMax() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // The survivor (smallest minted id) has the SMALLER lastVisited; the
        // loser carries the larger lastVisited which must be merged onto survivor.
        ctx.insert(makeHex("86lmax", first: utc(2026, 7, 23), last: utc(2026, 8, 1), count: 1, id: Self.mintedLow))
        ctx.insert(makeHex("86lmax", first: utc(2026, 9, 20), last: utc(2027, 4, 21), count: 1, id: Self.mintedHigh))
        try ctx.save()

        await HexVisitDeduplicator.deduplicateAll(modelContainer: container)

        let rows = try fetchAll(container).filter { $0.h3Index == "86lmax" }
        #expect(rows.count == 1)
        let survivor = try #require(rows.first)
        #expect(survivor.id == Self.mintedLow)
        #expect(survivor.lastVisited == utc(2027, 4, 21))
    }

    @Test("visitCount merges to MAX (8), not SUM (13); core idempotence invariant")
    func visitCountMergesToMaxNotSum() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // The survivor holds the smaller count, so the max must come from the donor.
        ctx.insert(makeHex("86vc", first: utc(2026, 7, 23), last: utc(2026, 7, 23), count: 5, id: Self.mintedLow))
        ctx.insert(makeHex("86vc", first: utc(2026, 8, 23), last: utc(2026, 8, 23), count: 8, id: Self.mintedHigh))
        try ctx.save()

        await HexVisitDeduplicator.deduplicateAll(modelContainer: container)

        let rows = try fetchAll(container).filter { $0.h3Index == "86vc" }
        #expect(rows.count == 1)
        let survivor = try #require(rows.first)
        #expect(survivor.id == Self.mintedLow)
        #expect(survivor.visitCount == 8)
        #expect(survivor.visitCount != 13)
    }

    @Test("locality backfilled from loser only when survivor's is nil; otherwise survivor keeps its own")
    func localityBackfilledWhenNil() async throws {
        // The survivor (smallest minted id) has nil locality → fills from loser.
        let containerA = try TestSupport.makeInMemoryContainer()
        let ctxA = ModelContext(containerA)
        ctxA.insert(makeHex("86locA", first: utc(2026, 7, 23), last: utc(2026, 7, 23), count: 1, locality: nil,
                            id: Self.mintedLow))
        ctxA.insert(makeHex("86locA", first: utc(2026, 9, 20), last: utc(2026, 9, 20), count: 1, locality: "Athens",
                            id: Self.mintedHigh))
        try ctxA.save()
        await HexVisitDeduplicator.deduplicateAll(modelContainer: containerA)
        let survivorA = try #require(try fetchAll(containerA).first { $0.h3Index == "86locA" })
        #expect(survivorA.id == Self.mintedLow)
        #expect(survivorA.locality == "Athens")

        // Survivor already has a locality → NOT overwritten by loser's.
        let containerB = try TestSupport.makeInMemoryContainer()
        let ctxB = ModelContext(containerB)
        ctxB.insert(makeHex("86locB", first: utc(2026, 7, 23), last: utc(2026, 7, 23), count: 1, locality: "Oslo",
                            id: Self.mintedLow))
        ctxB.insert(makeHex("86locB", first: utc(2026, 9, 20), last: utc(2026, 9, 20), count: 1, locality: "Bergen",
                            id: Self.mintedHigh))
        try ctxB.save()
        await HexVisitDeduplicator.deduplicateAll(modelContainer: containerB)
        let survivorB = try #require(try fetchAll(containerB).first { $0.h3Index == "86locB" })
        #expect(survivorB.id == Self.mintedLow)
        #expect(survivorB.locality == "Oslo")
    }

    @Test("country+iso backfilled together as a pair under the single country==nil guard")
    func countryAndIsoBackfilledTogetherWhenNil() async throws {
        // Survivor has nil country → both country AND iso copied from loser.
        let containerA = try TestSupport.makeInMemoryContainer()
        let ctxA = ModelContext(containerA)
        ctxA.insert(makeHex("86cA", first: utc(2026, 7, 23), last: utc(2026, 7, 23), count: 1, country: nil, iso: nil,
                            id: Self.mintedLow))
        ctxA.insert(makeHex("86cA", first: utc(2026, 9, 20), last: utc(2026, 9, 20), count: 1, country: "Greece", iso: "GR",
                            id: Self.mintedHigh))
        try ctxA.save()
        await HexVisitDeduplicator.deduplicateAll(modelContainer: containerA)
        let survivorA = try #require(try fetchAll(containerA).first { $0.h3Index == "86cA" })
        #expect(survivorA.id == Self.mintedLow)
        #expect(survivorA.country == "Greece")
        #expect(survivorA.isoCountryCode == "GR")

        // Survivor already has a complete pair → keeps its OWN country and iso,
        // never adopting the other row's.
        let containerB = try TestSupport.makeInMemoryContainer()
        let ctxB = ModelContext(containerB)
        ctxB.insert(makeHex("86cB", first: utc(2026, 7, 23), last: utc(2026, 7, 23), count: 1, country: "Norway", iso: "NO",
                            id: Self.mintedLow))
        ctxB.insert(makeHex("86cB", first: utc(2026, 9, 20), last: utc(2026, 9, 20), count: 1, country: "Sweden", iso: "SE",
                            id: Self.mintedHigh))
        try ctxB.save()
        await HexVisitDeduplicator.deduplicateAll(modelContainer: containerB)
        let survivorB = try #require(try fetchAll(containerB).first { $0.h3Index == "86cB" })
        #expect(survivorB.id == Self.mintedLow)
        #expect(survivorB.country == "Norway")
        #expect(survivorB.isoCountryCode == "NO")
    }

    /// The pair must never be mixed across rows: a survivor with a country but
    /// no ISO must NOT adopt an ISO belonging to a DIFFERENT country.
    @Test("a half-filled survivor never adopts a mismatched country's ISO")
    func isoIsNotAdoptedFromADifferentCountry() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // Force the half-filled Norway row to be the survivor.
        ctx.insert(makeHex("86mix", first: utc(2026, 7, 23), last: utc(2026, 7, 23), count: 1, country: "Norway", iso: nil,
                           id: Self.mintedLow))
        ctx.insert(makeHex("86mix", first: utc(2026, 9, 20), last: utc(2026, 9, 20), count: 1, country: "Sweden", iso: "SE",
                           id: Self.mintedHigh))
        try ctx.save()

        await HexVisitDeduplicator.deduplicateAll(modelContainer: container)

        let survivor = try #require(try fetchAll(container).first { $0.h3Index == "86mix" })
        #expect(survivor.id == Self.mintedLow)
        #expect(survivor.country == "Norway")
        // "SE" belongs to Sweden; adopting it would label this cell with
        // a country/ISO pair that contradicts itself.
        #expect(survivor.isoCountryCode == nil)
    }

    // MARK: - Idempotence + order independence

    @Test("running deduplicateAll twice is stable; visitCount/dates/count unchanged on the 2nd pass")
    func idempotentRunningTwiceIsStable() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        ctx.insert(makeHex("86idem", first: utc(2026, 7, 23), last: utc(2026, 7, 27), count: 5))
        ctx.insert(makeHex("86idem", first: utc(2026, 8, 23), last: utc(2027, 2, 20), count: 8))
        try ctx.save()

        await HexVisitDeduplicator.deduplicateAll(modelContainer: container)
        let after1 = try fetchAll(container).filter { $0.h3Index == "86idem" }
        #expect(after1.count == 1)
        let s1 = try #require(after1.first)
        let count1 = s1.visitCount
        let first1 = s1.firstVisited
        let last1 = s1.lastVisited

        await HexVisitDeduplicator.deduplicateAll(modelContainer: container)
        let after2 = try fetchAll(container).filter { $0.h3Index == "86idem" }
        #expect(after2.count == 1)
        let s2 = try #require(after2.first)
        #expect(s2.visitCount == count1)
        #expect(s2.firstVisited == first1)
        #expect(s2.lastVisited == last1)
        // Confirms max-merge converges; re-running does not re-inflate the count.
        #expect(s2.visitCount == 8)
    }

    @Test("survivor + merged fields are independent of insertion order")
    func orderIndependentSurvivorAndCounts() async throws {
        let early = utc(2026, 7, 23)
        let late = utc(2026, 12, 21)

        // Store A: early inserted first.
        let containerA = try TestSupport.makeInMemoryContainer()
        let ctxA = ModelContext(containerA)
        let a1 = makeHex("86ord", first: early, last: utc(2026, 7, 24), count: 3)
        let a2 = makeHex("86ord", first: late, last: utc(2027, 1, 20), count: 9)
        ctxA.insert(a1); ctxA.insert(a2)
        try ctxA.save()
        await HexVisitDeduplicator.deduplicateAll(modelContainer: containerA)
        let sA = try #require(try fetchAll(containerA).first { $0.h3Index == "86ord" })

        // Store B: late inserted first (opposite order), same id values reused
        // so the (firstVisited, id) survivor selection can be compared directly.
        let containerB = try TestSupport.makeInMemoryContainer()
        let ctxB = ModelContext(containerB)
        let b2 = makeHex("86ord", first: late, last: utc(2027, 1, 20), count: 9)
        b2.id = a2.id
        let b1 = makeHex("86ord", first: early, last: utc(2026, 7, 24), count: 3)
        b1.id = a1.id
        ctxB.insert(b2); ctxB.insert(b1)
        try ctxB.save()
        await HexVisitDeduplicator.deduplicateAll(modelContainer: containerB)
        let sB = try #require(try fetchAll(containerB).first { $0.h3Index == "86ord" })

        #expect(sA.id == sB.id)
        #expect(sA.visitCount == sB.visitCount)
        #expect(sA.firstVisited == sB.firstVisited)
        #expect(sA.lastVisited == sB.lastVisited)
    }

    @Test("multiple independent duplicate groups + a singleton: each group collapses, singleton untouched")
    func multipleIndependentDuplicateGroups() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // Group 1
        ctx.insert(makeHex("86g1", first: utc(2026, 7, 23), last: utc(2026, 7, 23), count: 2))
        ctx.insert(makeHex("86g1", first: utc(2026, 7, 24), last: utc(2026, 7, 24), count: 4))
        // Group 2
        ctx.insert(makeHex("86g2", first: utc(2026, 8, 23), last: utc(2026, 8, 23), count: 1))
        ctx.insert(makeHex("86g2", first: utc(2026, 8, 24), last: utc(2026, 8, 24), count: 6))
        // Singleton
        ctx.insert(makeHex("86g3", first: utc(2026, 9, 20), last: utc(2026, 9, 24), count: 3))
        try ctx.save()

        await HexVisitDeduplicator.deduplicateAll(modelContainer: container)

        let all = try fetchAll(container)
        #expect(all.count == 3)
        #expect(all.filter { $0.h3Index == "86g1" }.count == 1)
        #expect(all.filter { $0.h3Index == "86g2" }.count == 1)
        let singleton = try #require(all.first { $0.h3Index == "86g3" })
        #expect(singleton.visitCount == 3)
        #expect(singleton.lastVisited == utc(2026, 9, 24))
    }

    @Test("three-way duplicate group collapses to one survivor with max visitCount and max lastVisited")
    func threeWayDuplicateGroupKeepsOneMergesAll() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        ctx.insert(makeHex("863w", first: utc(2026, 7, 23), last: utc(2026, 8, 1), count: 4))
        ctx.insert(makeHex("863w", first: utc(2026, 8, 23), last: utc(2027, 7, 22), count: 11))
        ctx.insert(makeHex("863w", first: utc(2026, 9, 20), last: utc(2026, 11, 20), count: 7))
        try ctx.save()

        await HexVisitDeduplicator.deduplicateAll(modelContainer: container)

        let rows = try fetchAll(container).filter { $0.h3Index == "863w" }
        #expect(rows.count == 1)
        let survivor = try #require(rows.first)
        #expect(survivor.visitCount == 11)
        #expect(survivor.lastVisited == utc(2027, 7, 22))
        #expect(survivor.firstVisited == utc(2026, 7, 23))
    }

    @Test("group sharing the SAME id value is skipped; both rows survive, nothing mutated")
    func sharedIdGroupSkippedNotMerged() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let sharedUUID = UUID()
        let a = makeHex("86shared", first: utc(2026, 7, 23), last: utc(2026, 7, 23), count: 3)
        let b = makeHex("86shared", first: utc(2026, 8, 23), last: utc(2026, 8, 23), count: 9)
        ctx.insert(a)
        ctx.insert(b)
        a.id = sharedUUID
        b.id = sharedUUID
        try ctx.save()

        await HexVisitDeduplicator.deduplicateAll(modelContainer: container)

        let rows = try fetchAll(container).filter { $0.h3Index == "86shared" }
        // Both survive (skip-ambiguous guard) and neither was merged.
        #expect(rows.count == 2)
        #expect(rows.contains { $0.visitCount == 3 })
        #expect(rows.contains { $0.visitCount == 9 })
        // Identity is never rewritten: the retired repair used to
        // randomize these ids and let the next pass delete on them.
        #expect(rows.allSatisfy { $0.id == sharedUUID })
    }

    // MARK: - Replica-stable survivor

    private static let mintedLow = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private static let mintedHigh = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    private static let plainLow = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private static let plainHigh = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private static let sharedPlain = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private static let plainTop = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!

    @Test("init mints a zero-prefixed id that sorts before every plain id")
    func initMintsSortFirstIds() throws {
        let nearMiss = UUID(uuidString: "00000000-0001-4000-8000-000000000000")!
        #expect(!HexVisit.isMintedID(nearMiss))
        #expect(!HexVisit.isMintedID(Self.plainLow))
        #expect(HexVisit.isMintedID(Self.mintedLow))
        var seen = Set<UUID>()
        for _ in 0..<200 {
            let hex = makeHex("86mint", first: utc(2026, 7, 23), last: utc(2026, 7, 23), count: 1)
            #expect(HexVisit.isMintedID(hex.id))
            #expect(hex.id.uuidString < nearMiss.uuidString)
            // Version 4 and RFC 4122 variant bits survive the zero prefix.
            #expect(hex.id.uuid.6 >> 4 == 4)
            #expect(hex.id.uuid.8 >> 6 == 0b10)
            seen.insert(hex.id)
        }
        #expect(seen.count == 200)
    }

    /// Every id is locally unique, but the two replicas
    /// hold opposite values for the same two physical rows (a random repair
    /// on each, or two hydrations without `CD_id`). No plain id is trusted,
    /// so neither replica deletes and the cell keeps both rows.
    @Test("all-plain group with locally unique ids is skipped in both survivor orders")
    func allPlainGroupSkipped() async throws {
        for plainFirst in [false, true] {
            try await expectAllPlainGroupSkipped(plainFirst: plainFirst)
        }
    }

    private func expectAllPlainGroupSkipped(plainFirst: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let a = makeHex("86plain", first: utc(2026, 7, 23), last: utc(2026, 7, 25), count: 3, locality: "Samos")
        let b = makeHex("86plain", first: utc(2026, 8, 23), last: utc(2026, 8, 25), count: 9)
        a.id = plainFirst ? Self.plainLow : Self.plainHigh
        b.id = plainFirst ? Self.plainHigh : Self.plainLow
        ctx.insert(a)
        ctx.insert(b)
        try ctx.save()

        let completed = await HexVisitDeduplicator.deduplicateAll(modelContainer: container)

        #expect(completed)
        let rows = try fetchAll(container).filter { $0.h3Index == "86plain" }
        #expect(rows.count == 2)
        let rowA = try #require(rows.first { $0.visitCount == 3 })
        let rowB = try #require(rows.first { $0.visitCount == 9 })
        #expect(rowA.id == a.id && rowB.id == b.id)
        #expect(rowA.locality == "Samos" && rowB.locality == nil)
        #expect(rowB.firstVisited == utc(2026, 8, 23))
    }

    /// A same-cell pair where one row carries a migration default that is
    /// shared with a row in ANOTHER cell. The group-local guard saw a unique
    /// value there and deleted on it; now the plain pair stays, in both orders,
    /// and the other cell's row is untouched.
    @Test("a plain id shared across cells never decides a deletion, in both survivor orders")
    func crossCellSharedPlainIdSkipped() async throws {
        // plainLow sorts below the shared default, plainTop above it.
        for otherID in [Self.plainLow, Self.plainTop] {
            try await expectCrossCellSharedPlainIdSkipped(otherID: otherID)
        }
    }

    private func expectCrossCellSharedPlainIdSkipped(otherID: UUID) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let x = makeHex("86cellA", first: utc(2026, 7, 23), last: utc(2026, 7, 23), count: 2)
        let w = makeHex("86cellB", first: utc(2026, 7, 23), last: utc(2026, 7, 23), count: 5)
        let z = makeHex("86cellA", first: utc(2026, 9, 20), last: utc(2026, 9, 20), count: 7)
        x.id = Self.sharedPlain
        w.id = Self.sharedPlain
        z.id = otherID
        for hex in [x, w, z] { ctx.insert(hex) }
        try ctx.save()

        #expect(await HexVisitDeduplicator.deduplicateAll(modelContainer: container))

        let rows = try fetchAll(container)
        #expect(rows.count == 3)
        let cellAIDs = Set(rows.filter { $0.h3Index == "86cellA" }.map(\.id))
        #expect(cellAIDs == [Self.sharedPlain, otherID])
        let other = try #require(rows.first { $0.h3Index == "86cellB" })
        #expect(other.id == Self.sharedPlain && other.visitCount == 5)
    }

    @Test("a minted id shared by rows in two cells is not trusted")
    func sharedMintedIdSkipped() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let x = makeHex("86mA", first: utc(2026, 7, 23), last: utc(2026, 7, 23), count: 1)
        let w = makeHex("86mB", first: utc(2026, 7, 23), last: utc(2026, 7, 23), count: 1)
        let z = makeHex("86mA", first: utc(2026, 8, 23), last: utc(2026, 8, 23), count: 4)
        x.id = Self.mintedLow
        w.id = Self.mintedLow
        z.id = Self.mintedHigh
        for hex in [x, w, z] { ctx.insert(hex) }
        try ctx.save()

        #expect(await HexVisitDeduplicator.deduplicateAll(modelContainer: container))

        let rows = try fetchAll(container)
        #expect(rows.count == 3)
        #expect(rows.filter { $0.h3Index == "86mA" }.count == 2)
    }

    @Test("a mixed group keeps the minted row and absorbs the plain rows' data")
    func mixedGroupKeepsMintedSurvivor() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let legacyA = makeHex("86mix2", first: utc(2025, 11, 20), last: utc(2025, 11, 21), count: 12,
                              locality: "Kontakaíika", country: "Greece", iso: "GR")
        let legacyB = makeHex("86mix2", first: utc(2026, 2, 20), last: utc(2026, 2, 21), count: 2)
        let fresh = makeHex("86mix2", first: utc(2027, 1, 20), last: utc(2027, 1, 28), count: 1)
        legacyA.id = Self.sharedPlain
        legacyB.id = Self.sharedPlain
        let mintedID = fresh.id
        for hex in [legacyA, legacyB, fresh] { ctx.insert(hex) }
        try ctx.save()

        #expect(await HexVisitDeduplicator.deduplicateAll(modelContainer: container))

        let rows = try fetchAll(container).filter { $0.h3Index == "86mix2" }
        #expect(rows.count == 1)
        let survivor = try #require(rows.first)
        #expect(survivor.id == mintedID)
        #expect(survivor.firstVisited == utc(2025, 11, 20))
        #expect(survivor.lastVisited == utc(2027, 1, 28))
        #expect(survivor.visitCount == 12)
        #expect(survivor.locality == "Kontakaíika")
        #expect(survivor.country == "Greece" && survivor.isoCountryCode == "GR")
    }

    /// One physical row as one replica sees it.
    private struct ReplicaRow {
        let label: String
        let h3: String
        let id: UUID
    }

    /// Seeds one replica's view into its own store, runs the real
    /// deduplicator and returns the labels whose physical row it deleted.
    /// Deletions are detected by `persistentModelID`, not by a field the
    /// merge can rewrite.
    private func deletedLabels(in view: [ReplicaRow]) async throws -> Set<String> {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        var rows: [String: HexVisit] = [:]
        for row in view {
            let hex = makeHex(row.h3, first: utc(2026, 7, 23), last: utc(2026, 7, 23), count: 1)
            hex.id = row.id
            ctx.insert(hex)
            rows[row.label] = hex
        }
        try ctx.save()
        var physical: [String: PersistentIdentifier] = [:]
        for (label, hex) in rows { physical[label] = hex.persistentModelID }

        #expect(await HexVisitDeduplicator.deduplicateAll(modelContainer: container))

        let remaining = Set(try fetchAll(container).map(\.persistentModelID))
        return Set(physical.filter { !remaining.contains($0.value) }.map(\.key))
    }

    /// Two replicas dedup independently; each one's deletions then sync to
    /// the other. Every cell must keep at least one physical row.
    private func expectNoCellLost(_ a: [ReplicaRow], _ b: [ReplicaRow]) async throws -> Set<String> {
        let deletedOnA = try await deletedLabels(in: a)
        let deletedOnB = try await deletedLabels(in: b)
        let deleted = deletedOnA.union(deletedOnB)
        var cells: [String: [String]] = [:]
        for row in a + b { cells[row.h3, default: []].append(row.label) }
        for (cell, labels) in cells {
            #expect(Set(labels).subtracting(deleted).count >= 1, "cell \(cell) converged to zero rows")
        }
        return deleted
    }

    @Test("opposite plain ids on two replicas never delete opposite rows")
    func twoReplicaOppositePlainOrder() async throws {
        let replicaA = [
            ReplicaRow(label: "X", h3: "86war", id: Self.plainLow),
            ReplicaRow(label: "Y", h3: "86war", id: Self.plainHigh),
        ]
        let replicaB = [
            ReplicaRow(label: "X", h3: "86war", id: Self.plainHigh),
            ReplicaRow(label: "Y", h3: "86war", id: Self.plainLow),
        ]
        let deleted = try await expectNoCellLost(replicaA, replicaB)
        #expect(deleted.isEmpty)
    }

    /// Replica A still holds the migration default (shared with another
    /// cell); replica B hydrated the same record alone, so its default looks
    /// unique there. Both keep the minted row and only the legacy row goes.
    @Test("partial hydration and shared defaults converge on the minted row")
    func twoReplicaPartialHydration() async throws {
        let replicaA = [
            ReplicaRow(label: "X", h3: "86hyd", id: Self.sharedPlain),
            ReplicaRow(label: "W", h3: "86other", id: Self.sharedPlain),
            ReplicaRow(label: "Z", h3: "86hyd", id: Self.mintedHigh),
        ]
        let replicaB = [
            ReplicaRow(label: "X", h3: "86hyd", id: Self.plainLow),
            ReplicaRow(label: "Z", h3: "86hyd", id: Self.mintedHigh),
        ]
        let deleted = try await expectNoCellLost(replicaA, replicaB)
        #expect(deleted == ["X"])
    }

    /// A replica that has not yet received the smallest minted row keeps a
    /// larger one; the replica that has both keeps the smaller. The smaller
    /// is never deleted because only a replica that sees it can delete, and
    /// that replica keeps it.
    @Test("replicas seeing different minted rows still keep the smallest")
    func twoReplicaDifferentMintedViews() async throws {
        let replicaA = [
            ReplicaRow(label: "P", h3: "86view", id: Self.plainLow),
            ReplicaRow(label: "M1", h3: "86view", id: Self.mintedLow),
            ReplicaRow(label: "M2", h3: "86view", id: Self.mintedHigh),
        ]
        let replicaB = [
            ReplicaRow(label: "P", h3: "86view", id: Self.plainHigh),
            ReplicaRow(label: "M2", h3: "86view", id: Self.mintedHigh),
        ]
        let deleted = try await expectNoCellLost(replicaA, replicaB)
        #expect(deleted == ["P", "M2"])
    }
}
