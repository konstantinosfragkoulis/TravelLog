//
//  TripSorterOrderTests.swift
//  TravelLogTests
//
//  TripSorter.sort(_:by:photoService:) — the sort stage that runs AFTER
//  TripFilters.apply in the trips-list pipeline. Covers each TripSortOrder's
//  primary key (date, duration with the ongoing→Date.now end rule, country
//  count with empty-segment filtering, name via localizedCaseInsensitiveCompare)
//  and the deterministic tiebreaker chain (startDate desc → id.uuidString asc).
//  Constructs @Model objects and
//  calls @MainActor TripSorter, so this suite is @MainActor (synchronous —
//  TripSorter IS MainActor, no actor hop).
//
//  photoCount* real ranking is not unit-testable: it reads
//  PhotoService.cachedPhotoCount (private cache, no public setter), so in
//  tests every count is nil→0 and only the all-equal tiebreaker path is
//  observable — that path IS covered here.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct TripSorterOrderTests {

    // MARK: - Date helper

    private func day(_ year: Int, _ month: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: d, hour: 12))!
    }

    private func makeTrip(in ctx: ModelContext, start: Date) -> Trip {
        let trip = Trip(startDate: start)
        ctx.insert(trip)
        return trip
    }

    // MARK: - Date

    @Test("dateNewest sorts by startDate descending")
    func dateNewestDescendingByStartDate() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let old = makeTrip(in: ctx, start: day(2022, 1, 1))
        let mid = makeTrip(in: ctx, start: day(2023, 1, 1))
        let new = makeTrip(in: ctx, start: day(2024, 1, 1))

        let result = TripSorter.sort([old, new, mid], by: .dateNewest, photoService: .shared)
        #expect(result.map(\.id) == [new.id, mid.id, old.id])
    }

    @Test("dateOldest sorts by startDate ascending")
    func dateOldestAscendingByStartDate() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let old = makeTrip(in: ctx, start: day(2022, 1, 1))
        let mid = makeTrip(in: ctx, start: day(2023, 1, 1))
        let new = makeTrip(in: ctx, start: day(2024, 1, 1))

        let result = TripSorter.sort([new, old, mid], by: .dateOldest, photoService: .shared)
        #expect(result.map(\.id) == [old.id, mid.id, new.id])
    }

    @Test("equal startDate breaks ties by id.uuidString ascending (deterministic)")
    func dateTieBreaksByIdUuidStringAscending() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let same = day(2024, 5, 1)
        let a = makeTrip(in: ctx, start: same)
        let b = makeTrip(in: ctx, start: same)
        let c = makeTrip(in: ctx, start: same)
        let expected = [a, b, c].sorted { $0.id.uuidString < $1.id.uuidString }.map(\.id)

        // Shuffled input → same deterministic order proves stability.
        let r1 = TripSorter.sort([a, b, c], by: .dateNewest, photoService: .shared)
        let r2 = TripSorter.sort([c, a, b], by: .dateNewest, photoService: .shared)
        #expect(r1.map(\.id) == expected)
        #expect(r2.map(\.id) == expected)
        // .dateOldest applies the same id tiebreaker.
        let r3 = TripSorter.sort([b, c, a], by: .dateOldest, photoService: .shared)
        #expect(r3.map(\.id) == expected)
    }

    // MARK: - Duration

    @Test("durationLongest orders by trip length, longest first")
    func durationLongestOrdersByLength() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let short = makeTrip(in: ctx, start: day(2024, 6, 1)); short.endDate = day(2024, 6, 2)
        let mid = makeTrip(in: ctx, start: day(2024, 6, 1)); mid.endDate = day(2024, 6, 6)
        let long = makeTrip(in: ctx, start: day(2024, 6, 1)); long.endDate = day(2024, 6, 11)

        let result = TripSorter.sort([short, long, mid], by: .durationLongest, photoService: .shared)
        #expect(result.map(\.id) == [long.id, mid.id, short.id])
    }

    @Test("durationShortest is the ascending mirror of longest")
    func durationShortestReverseOfLongest() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let short = makeTrip(in: ctx, start: day(2024, 6, 1)); short.endDate = day(2024, 6, 2)
        let mid = makeTrip(in: ctx, start: day(2024, 6, 1)); mid.endDate = day(2024, 6, 6)
        let long = makeTrip(in: ctx, start: day(2024, 6, 1)); long.endDate = day(2024, 6, 11)

        let result = TripSorter.sort([long, short, mid], by: .durationShortest, photoService: .shared)
        #expect(result.map(\.id) == [short.id, mid.id, long.id])
    }

    @Test("an ongoing trip uses Date.now as its effective duration end")
    func ongoingTripUsesNowAsDurationEnd() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // Ongoing trip started 10 days ago → ~10-day effective duration.
        let ongoing = makeTrip(in: ctx, start: Date.now.addingTimeInterval(-10 * 86_400))
        // Completed 2-day trip — ongoing should outrank it.
        let twoDay = makeTrip(in: ctx, start: day(2020, 1, 1)); twoDay.endDate = day(2020, 1, 3)
        // Completed 30-day trip — should outrank the ongoing one.
        let thirtyDay = makeTrip(in: ctx, start: day(2020, 3, 1)); thirtyDay.endDate = day(2020, 3, 31)

        let result = TripSorter.sort([twoDay, ongoing, thirtyDay], by: .durationLongest, photoService: .shared)
        #expect(result.map(\.id) == [thirtyDay.id, ongoing.id, twoDay.id])
    }

    @Test("equal duration falls through to startDate desc, then id.uuidString")
    func durationTieFallsThroughToStartDateThenId() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // Same 3-day duration, different start dates.
        let earlier = makeTrip(in: ctx, start: day(2024, 1, 1)); earlier.endDate = day(2024, 1, 3)
        let later = makeTrip(in: ctx, start: day(2024, 6, 1)); later.endDate = day(2024, 6, 3)
        let result = TripSorter.sort([earlier, later], by: .durationLongest, photoService: .shared)
        #expect(result.map(\.id) == [later.id, earlier.id]) // startDate desc

        // Same duration AND same start → id.uuidString.
        let p = makeTrip(in: ctx, start: day(2025, 2, 1)); p.endDate = day(2025, 2, 3)
        let q = makeTrip(in: ctx, start: day(2025, 2, 1)); q.endDate = day(2025, 2, 3)
        let expected = [p, q].sorted { $0.id.uuidString < $1.id.uuidString }.map(\.id)
        let r2 = TripSorter.sort([q, p], by: .durationLongest, photoService: .shared)
        #expect(r2.map(\.id) == expected)
    }

    @Test("duration sorts rank by calendar days shown on the row, not elapsed seconds")
    func durationRanksByCalendarDaysNotSeconds() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        func at(_ d: Int, _ hour: Int) -> Date {
            Calendar.current.date(from: DateComponents(year: 2024, month: 6, day: d, hour: hour))!
        }
        // 14 h inside one day → "1 day"; 10 h across midnight → "2 days".
        let sameDay = makeTrip(in: ctx, start: at(15, 8)); sameDay.endDate = at(15, 22)
        let overnight = makeTrip(in: ctx, start: at(14, 21)); overnight.endDate = at(15, 7)
        #expect(sameDay.durationDays == 1)
        #expect(overnight.durationDays == 2)

        let longest = TripSorter.sort([sameDay, overnight], by: .durationLongest, photoService: .shared)
        #expect(longest.map(\.id) == [overnight.id, sameDay.id])
        let shortest = TripSorter.sort([overnight, sameDay], by: .durationShortest, photoService: .shared)
        #expect(shortest.map(\.id) == [sameDay.id, overnight.id])
    }

    @Test("duration sorts rank each UUID twin by its own length, whatever the input order")
    func durationRanksUUIDTwinsByOwnLength() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let oneDay = makeTrip(in: ctx, start: day(2024, 6, 1)); oneDay.endDate = day(2024, 6, 1)
        let fiveDays = makeTrip(in: ctx, start: day(2024, 7, 1)); fiveDays.endDate = day(2024, 7, 5)
        let tenDays = makeTrip(in: ctx, start: day(2024, 8, 1)); tenDays.endDate = day(2024, 8, 10)
        tenDays.id = oneDay.id
        #expect([oneDay, fiveDays, tenDays].map(\.durationDays) == [1, 5, 10])

        let longest = [tenDays, fiveDays, oneDay].map(ObjectIdentifier.init)
        let shortest = [oneDay, fiveDays, tenDays].map(ObjectIdentifier.init)
        for input in [[oneDay, fiveDays, tenDays], [tenDays, fiveDays, oneDay]] {
            let l = TripSorter.sort(input, by: .durationLongest, photoService: .shared)
            #expect(l.map(ObjectIdentifier.init) == longest)
            let s = TripSorter.sort(input, by: .durationShortest, photoService: .shared)
            #expect(s.map(ObjectIdentifier.init) == shortest)
        }
    }

    // MARK: - Significance ("Biggest First")

    /// Attach a destination stay at `distanceKm` from home so
    /// `TripSorter.significance` has a stored farthest-distance to read.
    private func addStay(
        to trip: Trip, in ctx: ModelContext, distanceKm: Double
    ) {
        let stay = Stay(
            startTime: trip.startDate,
            endTime: trip.startDate.addingTimeInterval(3600),
            centroidLatitude: 37.9838,
            centroidLongitude: 23.7275,
            h3IndexRes6: "861f01867ffffff",
            pingCount: 4,
            distanceFromHomeKm: distanceKm,
            pingIDs: []
        )
        ctx.insert(stay)
        stay.trip = trip
    }

    @Test("significanceHighest ranks a far long trip over a near day trip")
    func significanceRanksFarLongOverNearShort() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // 14-day, 7 800 km trip vs a same-year 1-day, 50 km day trip. The
        // day trip is NEWER — dateNewest would put it first; significance
        // must not.
        let farTrip = makeTrip(in: ctx, start: day(2025, 6, 14)); farTrip.endDate = day(2025, 6, 28)
        addStay(to: farTrip, in: ctx, distanceKm: 7800)
        let nearTrip = makeTrip(in: ctx, start: day(2025, 12, 15)); nearTrip.endDate = day(2025, 12, 15)
        addStay(to: nearTrip, in: ctx, distanceKm: 50)
        try ctx.save()

        let result = TripSorter.sort([nearTrip, farTrip], by: .significanceHighest, photoService: .shared)
        #expect(result.map(\.id) == [farTrip.id, nearTrip.id])
    }

    @Test("equal farthest distance falls through to duration (longer trip ranks higher)")
    func significanceEqualDistanceLongerDurationWins() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let week = makeTrip(in: ctx, start: day(2025, 6, 1)); week.endDate = day(2025, 6, 8)
        addStay(to: week, in: ctx, distanceKm: 170)
        let weekend = makeTrip(in: ctx, start: day(2025, 7, 1)); weekend.endDate = day(2025, 7, 3)
        addStay(to: weekend, in: ctx, distanceKm: 170)
        try ctx.save()

        let result = TripSorter.sort([weekend, week], by: .significanceHighest, photoService: .shared)
        #expect(result.map(\.id) == [week.id, weekend.id])
    }

    @Test("a trip with no stays scores 0 and sinks below scored trips")
    func significanceNoStaysSinksToBottom() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let scored = makeTrip(in: ctx, start: day(2023, 1, 1)); scored.endDate = day(2023, 1, 2)
        addStay(to: scored, in: ctx, distanceKm: 100)
        // Newer, longer, but stay-less — must still rank below.
        let bare = makeTrip(in: ctx, start: day(2025, 1, 1)); bare.endDate = day(2025, 1, 20)
        try ctx.save()

        let result = TripSorter.sort([bare, scored], by: .significanceHighest, photoService: .shared)
        #expect(result.map(\.id) == [scored.id, bare.id])
    }

    @Test("equal scores fall through to startDate desc, then id.uuidString")
    func significanceTieFallsThroughToStartDateThenId() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // Identical distance AND duration → identical score.
        let earlier = makeTrip(in: ctx, start: day(2024, 1, 1)); earlier.endDate = day(2024, 1, 3)
        addStay(to: earlier, in: ctx, distanceKm: 300)
        let later = makeTrip(in: ctx, start: day(2024, 6, 1)); later.endDate = day(2024, 6, 3)
        addStay(to: later, in: ctx, distanceKm: 300)
        try ctx.save()

        let result = TripSorter.sort([earlier, later], by: .significanceHighest, photoService: .shared)
        #expect(result.map(\.id) == [later.id, earlier.id]) // startDate desc
    }

    @Test("significance is the TripConfidence score over farthest stay distance and duration at unit scale")
    func significanceMatchesTripConfidenceFormula() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = makeTrip(in: ctx, start: day(2025, 4, 1)); trip.endDate = day(2025, 4, 4)
        addStay(to: trip, in: ctx, distanceKm: 120)
        addStay(to: trip, in: ctx, distanceKm: 450) // farthest — must win the max
        try ctx.save()

        let now = Date.now
        let expected = TripConfidence.score(
            distanceKm: 450,
            durationHours: trip.endDate!.timeIntervalSince(trip.startDate) / 3600,
            scaleKm: 1
        )
        #expect(TripSorter.significance(trip, now: now) == expected)
        #expect(expected > 0)
    }

    @Test("significanceHighest ranks each UUID twin by its own score, whatever the input order")
    func significanceRanksUUIDTwinsByOwnScore() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let near = makeTrip(in: ctx, start: day(2025, 12, 15)); near.endDate = day(2025, 12, 15)
        addStay(to: near, in: ctx, distanceKm: 50)
        let middle = makeTrip(in: ctx, start: day(2025, 8, 14)); middle.endDate = day(2025, 8, 17)
        addStay(to: middle, in: ctx, distanceKm: 300)
        let far = makeTrip(in: ctx, start: day(2025, 6, 14)); far.endDate = day(2025, 6, 28)
        addStay(to: far, in: ctx, distanceKm: 7800)
        far.id = near.id
        try ctx.save()

        let expected = [far, middle, near].map(ObjectIdentifier.init)
        for input in [[near, middle, far], [far, middle, near]] {
            let result = TripSorter.sort(input, by: .significanceHighest, photoService: .shared)
            #expect(result.map(ObjectIdentifier.init) == expected)
        }
    }

    // MARK: - Country count

    @Test("countryCountHighest orders by unique-code count")
    func countryCountHighestOrdersByUniqueCodeCount() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let three = makeTrip(in: ctx, start: day(2024, 1, 1)); three.countryCodes = "GR,IT,FR"
        let two = makeTrip(in: ctx, start: day(2024, 2, 1)); two.countryCodes = "GR,IT"
        let one = makeTrip(in: ctx, start: day(2024, 3, 1)); one.countryCodes = "GR"
        let zero = makeTrip(in: ctx, start: day(2024, 4, 1)); zero.countryCodes = ""

        let result = TripSorter.sort([one, zero, three, two], by: .countryCountHighest, photoService: .shared)
        // Hoisted into typed bindings: the inline 4-element [UUID] literal vs
        // .map(\.id) inside #expect blows the type-checker's time budget.
        let got: [UUID] = result.map(\.id)
        let want: [UUID] = [three.id, two.id, one.id, zero.id]
        #expect(got == want)
    }

    @Test("country count ignores empty comma segments (GR,,IT counts 2)")
    func countryCountIgnoresEmptyCommaSegments() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // Same start date so the only differentiator is the count (then id).
        let same = day(2024, 7, 1)
        let dirty = makeTrip(in: ctx, start: same); dirty.countryCodes = "GR,,IT"
        let clean = makeTrip(in: ctx, start: same); clean.countryCodes = "GR,IT"
        let single = makeTrip(in: ctx, start: same); single.countryCodes = "GR"

        let result = TripSorter.sort([single, dirty, clean], by: .countryCountHighest, photoService: .shared)
        // dirty and clean both count 2 → ranked above single; their mutual
        // order falls through to id.uuidString (same startDate).
        let topTwo = Set(result.prefix(2).map(\.id))
        #expect(topTwo == Set([dirty.id, clean.id]))
        #expect(result.last?.id == single.id)
    }

    @Test("countryCountHighest ranks each UUID twin by its own countries, whatever the input order")
    func countryCountRanksUUIDTwinsByOwnCount() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let one = makeTrip(in: ctx, start: day(2024, 1, 1)); one.countryCodes = "GR"
        let two = makeTrip(in: ctx, start: day(2024, 2, 1)); two.countryCodes = "GR,IT"
        let three = makeTrip(in: ctx, start: day(2024, 3, 1)); three.countryCodes = "GR,IT,FR"
        three.id = one.id

        let expected = [three, two, one].map(ObjectIdentifier.init)
        for input in [[one, two, three], [three, two, one]] {
            let result = TripSorter.sort(input, by: .countryCountHighest, photoService: .shared)
            #expect(result.map(ObjectIdentifier.init) == expected)
        }
    }

    // MARK: - Name

    @Test("nameAZ uses localizedCaseInsensitiveCompare (athens < Berlin < oslo)")
    func nameAZCaseInsensitiveLocalizedAscending() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let athens = makeTrip(in: ctx, start: day(2024, 1, 1)); athens.customName = "athens"
        let berlin = makeTrip(in: ctx, start: day(2024, 2, 1)); berlin.customName = "Berlin"
        let oslo = makeTrip(in: ctx, start: day(2024, 3, 1)); oslo.customName = "oslo"

        let result = TripSorter.sort([oslo, athens, berlin], by: .nameAZ, photoService: .shared)
        #expect(result.map(\.id) == [athens.id, berlin.id, oslo.id])
    }

    @Test("nameAZ ties break by startDate desc, then id.uuidString")
    func nameAZTieBreaksByStartDateThenId() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let earlier = makeTrip(in: ctx, start: day(2024, 1, 1)); earlier.customName = "Paris"
        let later = makeTrip(in: ctx, start: day(2024, 6, 1)); later.customName = "Paris"

        let result = TripSorter.sort([earlier, later], by: .nameAZ, photoService: .shared)
        #expect(result.map(\.id) == [later.id, earlier.id]) // startDate desc
    }

    @Test("nameAZ preserves physical UUID twins, repeated occurrences, and full ties")
    func nameAZPreservesUUIDTwinsAndOccurrences() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let alpha = makeTrip(in: context, start: start); alpha.customName = "Alpha"
        let zulu = makeTrip(in: context, start: start); zulu.customName = "Zulu"
        let tie = makeTrip(in: context, start: start); tie.customName = "alpha"
        let laterID = makeTrip(in: context, start: start); laterID.customName = "Alpha"
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        for trip in [alpha, zulu, tie] { trip.id = id }
        laterID.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let result = TripSorter.sort([zulu, tie, laterID, alpha, zulu], by: .nameAZ, photoService: .shared)
        let expected = [tie, alpha, laterID, zulu, zulu]
        #expect(result.map(ObjectIdentifier.init) == expected.map(ObjectIdentifier.init))
    }

    // MARK: - Photo count (all-uncached → tiebreaker only)

    @Test("photoCountHighest with all-uncached trips falls through to startDate/id tiebreakers")
    func photoCountAllUncachedFallsThroughToTieBreakers() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let old = makeTrip(in: ctx, start: day(2022, 1, 1))
        let mid = makeTrip(in: ctx, start: day(2023, 1, 1))
        let new = makeTrip(in: ctx, start: day(2024, 1, 1))

        // All counts nil→0 → governed entirely by startDate desc tiebreaker.
        let result = TripSorter.sort([old, new, mid], by: .photoCountHighest, photoService: .shared)
        #expect(result.map(\.id) == [new.id, mid.id, old.id])
    }
}
