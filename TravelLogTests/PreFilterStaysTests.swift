//
//  PreFilterStaysTests.swift
//  TravelLogTests
//
//  Stage 1 pre-filtering - TripClassifier.preFilterStays(). Classifies
//  obviously-home / obviously-routine unclassified stays by radius against the
//  Home / RoutinePlace records, in two passes:
//
//    Pass 1 (strict time-window): a stay matches a Home/RoutinePlace iff the
//      record was actively tracking at the stay's startTime - i.e.
//      `record.startedAt <= stay.startTime` AND (record.endedAt == nil ||
//      stay.startTime <= record.endedAt) - AND the stay's centroid is inside
//      the record's radius.
//
//    Pass 2 (current-record fallback): if no Pass-1 match AND
//      the stay predates EVERY Home record (`stay.startTime < every
//      Home.startedAt`) AND a current (endedAt == nil) Home exists, the current
//      Home is applied as if it had always existed. This fixes the photo-import
//      bug where stays years before the first Home record were never classified
//      `.home`, leaving zero trip boundaries and collapsing all history into one
//      giant 2000-day trip. The "predates EVERY Home" gate is load-bearing: it
//      prevents the fallback from papering over a legitimate gap (a stay between
//      two historical Homes' active periods, at a third location).
//
//  `preFilterStays()` MUTATES its actor's own modelContext and returns the
//  count of stays it classified; it does NOT save (the pipeline persists later).
//  So, exactly like ClassifierSanityCheckTests, the cross-context observables in
//  a unit test are (a) the return count and (b) the in-context category read
//  back THROUGH the actor via the #if DEBUG `stayCategoryForTesting` accessor -
//  a fresh ModelContext cannot see the actor's unsaved changes. We must
//  `try ctx.save()` AFTER seeding so the actor's own context can fetch the
//  seeded Home/RoutinePlace/Stay rows.
//
//  `@MainActor` because the app target is MainActor-by-default, which makes the
//  @Model types (Stay/Home/RoutinePlace) and the @ModelActor TripClassifier
//  touchable here; the actor-isolated preFilterStays is awaited.
//

import Testing
import Foundation
import SwiftData
import CoreLocation
@testable import TravelLog

@MainActor
struct PreFilterStaysTests {

    // Athens anchor for Home and RoutinePlace.
    nonisolated static let athens = (lat: 38.0705, lon: 23.7040)
    // ~4.2 km from the Athens anchor: INSIDE the 25 km Home radius (verified via
    // CLLocation), OUTSIDE the 500 m RoutinePlace radius.
    static let athensNearby = (lat: 38.0367, lon: 23.7265)
    // ~100 m from the Athens anchor: INSIDE the 500 m RoutinePlace radius.
    static let athensVeryNear = (lat: 38.0714, lon: 23.7040)
    // Ioánnina is ~303 km from the Athens anchor, outside every home radius.
    static let ioannina = (lat: 39.6628, lon: 20.8612)

    // Deterministic reference instant; all windows/stays are offsets from it.
    static let t0 = Date(timeIntervalSinceReferenceDate: 17_539_200)
    private static func day(_ n: Double) -> Date {
        t0.addingTimeInterval(n * 86_400)
    }

    @discardableResult
    private func makeStay(
        in ctx: ModelContext,
        at coord: (lat: Double, lon: Double),
        start: Date,
        hex: String
    ) -> Stay {
        // The Stay init sets categoryRaw to "unclassified" (the exact value the
        // preFilterStays predicate filters on), so a freshly-inited stay is a
        // valid pre-filter candidate without touching `category`.
        let stay = Stay(
            startTime: start,
            endTime: start.addingTimeInterval(3600),
            centroidLatitude: coord.lat,
            centroidLongitude: coord.lon,
            h3IndexRes6: hex,
            pingCount: 1,
            distanceFromHomeKm: 0,
            pingIDs: []
        )
        ctx.insert(stay)
        return stay
    }

    @discardableResult
    private func makeHome(
        in ctx: ModelContext,
        at coord: (lat: Double, lon: Double) = athens,
        startedAt: Date,
        endedAt: Date? = nil,
        radiusKm: Double = 25
    ) -> Home {
        let home = Home(
            label: "H",
            latitude: coord.lat,
            longitude: coord.lon,
            radiusKm: radiusKm,
            startedAt: startedAt
        )
        home.endedAt = endedAt
        ctx.insert(home)
        return home
    }

    @discardableResult
    private func makeRoutine(
        in ctx: ModelContext,
        at coord: (lat: Double, lon: Double) = athens,
        startedAt: Date,
        endedAt: Date? = nil,
        radiusMeters: Double = 500
    ) -> RoutinePlace {
        let place = RoutinePlace(
            label: "R",
            latitude: coord.lat,
            longitude: coord.lon,
            radiusMeters: radiusMeters,
            startedAt: startedAt
        )
        place.endedAt = endedAt
        ctx.insert(place)
        return place
    }

    // MARK: - Pass 1: strict time-window Home matches

    @Test("a stay inside an ACTIVE Home's window (and radius) is classified .home")
    func stayInsideActiveHomeWindowBecomesHome() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // Current home: startedAt day 0, never ended.
        makeHome(in: ctx, startedAt: Self.day(0), endedAt: nil)
        // Stay one day into the active window, ~4.2 km away (inside 25 km).
        let stay = makeStay(in: ctx, at: Self.athensNearby, start: Self.day(1), hex: "ah")
        try ctx.save() // actor's own context must see the seed before fetching

        let count = await classifier.preFilterStays()

        #expect(await classifier.stayCategoryForTesting(stay.id) == .home)
        #expect(count == 1)
    }

    @Test("a stay inside an ENDED Home's active window (startedAt..endedAt) is classified .home")
    func stayInsideEndedHomeWindowBecomesHome() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // Historical home: active day 0 → day 100, then ended. No current home,
        // so Pass 2 cannot fire (its `!currentHomes.isEmpty` gate is false) - the
        // .home result is therefore unambiguously a Pass-1 (window) match.
        makeHome(in: ctx, startedAt: Self.day(0), endedAt: Self.day(100))
        // Stay mid-window (day 50), inside the radius.
        let stay = makeStay(in: ctx, at: Self.athensNearby, start: Self.day(50), hex: "eh")
        try ctx.save()

        let count = await classifier.preFilterStays()

        #expect(await classifier.stayCategoryForTesting(stay.id) == .home)
        #expect(count == 1)
    }

    @Test("a stay AFTER an ended Home's endedAt is NOT matched (window closed, no current-home fallback)")
    func stayAfterEndedHomeNotMatched() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // ONLY a historical home (ended at day 100), no current home → Pass 2 is
        // gated off by `!currentHomes.isEmpty`. The stay sits at day 200, after
        // the window closed, so Pass 1 skips it (`stay.startTime > endedAt`).
        makeHome(in: ctx, startedAt: Self.day(0), endedAt: Self.day(100))
        // Same Athens location (inside the radius) to prove it's the TIME, not the
        // distance, that excludes it.
        let stay = makeStay(in: ctx, at: Self.athensNearby, start: Self.day(200), hex: "ph")
        try ctx.save()

        let count = await classifier.preFilterStays()

        #expect(await classifier.stayCategoryForTesting(stay.id) == .unclassified)
        #expect(count == 0)
    }

    // MARK: - Pass 2: current-home fallback

    @Test("a stay that predates ALL homes, inside the current home's radius, is force-classified .home")
    func predatesAllHomesInsideCurrentHomeBecomesHome() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // Current home started day 100. Stay at day 0 predates it → no Pass-1
        // match, but `predatesAllHomes` is true and the current home contains the
        // point, so the fallback classifies it .home. This is the photo-import
        // fix: stays years before the first Home record still get a .home anchor.
        makeHome(in: ctx, startedAt: Self.day(100), endedAt: nil)
        let stay = makeStay(in: ctx, at: Self.athensNearby, start: Self.day(0), hex: "fb")
        try ctx.save()

        let count = await classifier.preFilterStays()

        #expect(await classifier.stayCategoryForTesting(stay.id) == .home)
        #expect(count == 1)
    }

    @Test("predates-all-homes fallback does NOT fire when there is no current home (only an ended one)")
    func predatesAllHomesButNoCurrentHomeNotMatched() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // The ONLY home is historical (ended). A stay at day 0 predates its
        // startedAt (day 100), but there is no current home, so the fallback's
        // `!currentHomes.isEmpty` gate is false → stay stays unclassified.
        makeHome(in: ctx, startedAt: Self.day(100), endedAt: Self.day(200))
        let stay = makeStay(in: ctx, at: Self.athensNearby, start: Self.day(0), hex: "nc")
        try ctx.save()

        let count = await classifier.preFilterStays()

        #expect(await classifier.stayCategoryForTesting(stay.id) == .unclassified)
        #expect(count == 0)
    }

    @Test("a stay in the GAP between two historical/current homes (third location) is NOT force-matched")
    func stayBetweenTwoHomesNegativeGapNotForceMatched() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // Home1: historical, active day 0 → day 100 (Athens).
        // Home2: current, active from day 300 (Athens), endedAt nil.
        // Stay at day 200 sits in the gap between the two homes' windows, at
        // IOÁNNINA (a third location, ~303 km away).
        makeHome(in: ctx, startedAt: Self.day(0), endedAt: Self.day(100))
        makeHome(in: ctx, startedAt: Self.day(300), endedAt: nil)
        let stay = makeStay(in: ctx, at: Self.ioannina, start: Self.day(200), hex: "gap")
        try ctx.save()

        let count = await classifier.preFilterStays()

        // Pass 1: Home1 window closed (200 > 100), Home2 not yet started (300 >
        // 200) → no match. Pass 2: a current home exists, but `predatesAllHomes`
        // is FALSE (200 is not < Home1.startedAt day 0), so the fallback is
        // correctly suppressed - preventing the over-eager force-match that
        // caused the 2000-day single-trip bug.
        #expect(await classifier.stayCategoryForTesting(stay.id) == .unclassified)
        #expect(count == 0)
    }

    @Test("the predates-EVERY-home gate, not the location, suppresses the gap force-match")
    func gapGateIsAboutTimeNotLocation() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // Same two-home gap as above, but the gap stay is AT the (current) home's
        // location (inside its radius). It is still NOT classified .home, because
        // `predatesAllHomes` is false (day 150 is after Home1.startedAt day 0).
        // This isolates the GATE: only time, not radius, blocks the fallback here.
        makeHome(in: ctx, startedAt: Self.day(0), endedAt: Self.day(100))
        makeHome(in: ctx, startedAt: Self.day(300), endedAt: nil)
        let stay = makeStay(in: ctx, at: Self.athensNearby, start: Self.day(150), hex: "gat")
        try ctx.save()

        let count = await classifier.preFilterStays()

        #expect(await classifier.stayCategoryForTesting(stay.id) == .unclassified)
        #expect(count == 0)
    }

    // MARK: - Outside radius / no records

    @Test("a stay outside the home radius (active window) is NOT classified .home")
    func stayOutsideRadiusNotHome() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // Active home in Athens; stay at Ioánnina (~303 km) inside the
        // window. The window matches but the radius does not → unclassified.
        makeHome(in: ctx, startedAt: Self.day(0), endedAt: nil)
        let stay = makeStay(in: ctx, at: Self.ioannina, start: Self.day(1), hex: "out")
        try ctx.save()

        let count = await classifier.preFilterStays()

        #expect(await classifier.stayCategoryForTesting(stay.id) == .unclassified)
        #expect(count == 0)
    }

    @Test("with no Home or RoutinePlace records, an unclassified stay stays unclassified (count 0)")
    func noRecordsLeavesStayUnclassified() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let stay = makeStay(in: ctx, at: Self.athensNearby, start: Self.day(0), hex: "none")
        try ctx.save()

        let count = await classifier.preFilterStays()

        #expect(await classifier.stayCategoryForTesting(stay.id) == .unclassified)
        #expect(count == 0)
    }

    // MARK: - RoutinePlace symmetry

    @Test("a stay inside an active RoutinePlace window/radius (not home) is classified .routine")
    func stayInsideRoutinePlaceBecomesRoutine() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // No home at all → home passes can't fire. A current routine place
        // (500 m) anchored at Athens; stay ~100 m away, inside its window.
        makeRoutine(in: ctx, startedAt: Self.day(0), endedAt: nil)
        let stay = makeStay(in: ctx, at: Self.athensVeryNear, start: Self.day(1), hex: "rp")
        try ctx.save()

        let count = await classifier.preFilterStays()

        #expect(await classifier.stayCategoryForTesting(stay.id) == .routine)
        #expect(count == 1)
    }

    @Test("the predates-all-homes routine fallback classifies a stay before all routine records")
    func predatesAllRoutinePlacesInsideCurrentRoutineBecomesRoutine() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // No homes. Current routine place started day 100; stay at day 0 predates
        // it. Pass-2 routine fallback fires (predatesAllPlaces true, current place
        // contains the ~100 m point) → .routine.
        makeRoutine(in: ctx, startedAt: Self.day(100), endedAt: nil)
        let stay = makeStay(in: ctx, at: Self.athensVeryNear, start: Self.day(0), hex: "rfb")
        try ctx.save()

        let count = await classifier.preFilterStays()

        #expect(await classifier.stayCategoryForTesting(stay.id) == .routine)
        #expect(count == 1)
    }

    @Test("Home takes precedence over RoutinePlace when a stay is inside both")
    func homeTakesPrecedenceOverRoutine() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // Both anchored near Athens, both active. The ~100 m stay is inside the
        // 25 km home AND the 500 m routine place. preFilterStays checks home
        // first and `break`s, so the category is .home (routine is only checked
        // `if stay.category == .unclassified`).
        makeHome(in: ctx, startedAt: Self.day(0), endedAt: nil)
        makeRoutine(in: ctx, startedAt: Self.day(0), endedAt: nil)
        let stay = makeStay(in: ctx, at: Self.athensVeryNear, start: Self.day(1), hex: "hr")
        try ctx.save()

        let count = await classifier.preFilterStays()

        #expect(await classifier.stayCategoryForTesting(stay.id) == .home)
        #expect(count == 1) // counted once, as home - not double-counted
    }

    // MARK: - Boundary: window edges are inclusive

    @Test("window edges are inclusive: stay exactly AT startedAt and exactly AT endedAt both match .home")
    func windowEdgesAreInclusive() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // Ended home active day 0 → day 100. Two stays: one exactly at startedAt
        // (day 0), one exactly at endedAt (day 100). Pass-1 uses `startedAt >
        // startTime` (so == is NOT skipped) and `startTime > endedAt` (so == is
        // NOT skipped) → both edges are inclusive → both .home. No current home,
        // so this is purely the Pass-1 window boundary.
        makeHome(in: ctx, startedAt: Self.day(0), endedAt: Self.day(100))
        let atStart = makeStay(in: ctx, at: Self.athensNearby, start: Self.day(0), hex: "ws")
        let atEnd = makeStay(in: ctx, at: Self.athensNearby, start: Self.day(100), hex: "we")
        try ctx.save()

        let count = await classifier.preFilterStays()

        #expect(await classifier.stayCategoryForTesting(atStart.id) == .home)
        #expect(await classifier.stayCategoryForTesting(atEnd.id) == .home)
        #expect(count == 2)
    }

    // MARK: - Aggregate count

    @Test("return count aggregates only the classified stays in one pass")
    func returnCountAggregatesClassifiedOnly() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // Active home + active routine place in Athens.
        makeHome(in: ctx, startedAt: Self.day(0), endedAt: nil)
        makeRoutine(in: ctx, startedAt: Self.day(0), endedAt: nil)

        // One stay inside the home radius (→ home), one far from every record
        // (→ unclassified, must NOT inflate the count).
        let homeStay = makeStay(in: ctx, at: Self.athensNearby, start: Self.day(1), hex: "c1")
        // A stay far from any record → stays unclassified, must NOT be counted.
        let awayStay = makeStay(in: ctx, at: Self.ioannina, start: Self.day(2), hex: "c2")
        try ctx.save()

        let count = await classifier.preFilterStays()

        // Only the home stay is classified; the away stay is not → count == 1.
        #expect(await classifier.stayCategoryForTesting(homeStay.id) == .home)
        #expect(await classifier.stayCategoryForTesting(awayStay.id) == .unclassified)
        #expect(count == 1)
    }
}

// MARK: - Ending a home must not erase pre-history home stays

//  `matchesHome` pass 2 filtered to `endedAt == nil`, which made ending
//  a home RETROACTIVE: for a stay predating every home record, "is this home
//  still active?" is meaningless (every home window lies in that stay's
//  future), yet ending home A stopped A's ring from matching pre-history
//  stays. `applyHomeChangeCore`'s stale-home pass then unstamped every one of
//  them, dissolving the trip boundaries of the whole imported era.
extension PreFilterStaysTests {

    private var year2016: Date { Date(timeIntervalSince1970: 1_451_606_400) } // 2016-01-01
    private var year2024: Date { Date(timeIntervalSince1970: 1_704_067_200) } // 2024-01-01
    private var year2025: Date { Date(timeIntervalSince1970: 1_735_689_600) } // 2025-01-01

    /// Athens and Berlin - far enough apart that neither ring contains the other.
    private var athensCenter: (lat: Double, lon: Double) { (lat: 37.9838, lon: 23.7275) }
    private var berlin: (lat: Double, lon: Double) { (lat: 52.5739, lon: 13.4172) }

    private func ring(
        _ coord: (lat: Double, lon: Double),
        startedAt: Date,
        endedAt: Date? = nil,
        radiusKm: Double = 3
    ) -> TripClassifier.HomeRing {
        TripClassifier.HomeRing(
            latitude: coord.lat,
            longitude: coord.lon,
            radiusKm: radiusKm,
            startedAt: startedAt,
            endedAt: endedAt
        )
    }

    private func matches(_ coord: (lat: Double, lon: Double), at start: Date, homes: [TripClassifier.HomeRing]) -> Bool {
        TripClassifier.matchesHome(
            stayStart: start,
            latitude: coord.lat,
            longitude: coord.lon,
            homes: homes
        )
    }

    @Test("Pre-history stay matches its home ring even after that home is ended")
    func preHistoryStaySurvivesHomeReplacement() {
        // Before the move: one active Athens home registered in 2024. A 2016
        // Athens stay predates it and matches via pass 2 - this is what gives
        // the imported era its trip boundaries.
        let beforeMove = [ring(athensCenter, startedAt: year2024)]
        #expect(matches(athensCenter, at: year2016, homes: beforeMove))

        // "I Moved - Replace Existing": Athens gains an endedAt, Berlin is
        // added. The 2016 Athens stay STILL predates every home record, so it
        // must still classify as home. Pre-fix this returned false, and the
        // stale-home pass unstamped it (and every stay like it).
        let afterMove = [
            ring(athensCenter, startedAt: year2024, endedAt: year2025),
            ring(berlin, startedAt: year2025),
        ]
        #expect(matches(athensCenter, at: year2016, homes: afterMove))
    }

    @Test("Pass 1 window semantics are unchanged by the pass-2 fix")
    func endedHomeStillBoundsItsOwnWindow() {
        let homes = [
            ring(athensCenter, startedAt: year2024, endedAt: year2025),
            ring(berlin, startedAt: year2025),
        ]
        // Inside Athens' active window -> home.
        #expect(matches(athensCenter, at: year2024.addingTimeInterval(86_400), homes: homes))
        // AFTER Athens ended, an Athens stay is a trip, not home. Pass 2 must
        // not rescue it: the stay does not predate every home record.
        #expect(!matches(athensCenter, at: year2025.addingTimeInterval(86_400), homes: homes))
        // Berlin during its own window is home.
        #expect(matches(berlin, at: year2025.addingTimeInterval(86_400), homes: homes))
    }
}
