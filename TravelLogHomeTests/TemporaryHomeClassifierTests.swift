//
//  TemporaryHomeClassifierTests.swift
//  TravelLogTests
//
//  A temporary home is a second trip boundary inside its own dates and
//  nothing else: it never claims a stay that predates the real homes, never
//  measures a stay outside its dates, never counts as a homecoming, and
//  learns no orbit. A user with no temporary home gets the old answers.
//

import CoreLocation
import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
struct TemporaryHomeClassifierTests {

    private static let day: TimeInterval = 24 * 60 * 60
    private static let athens = (lat: 38.0, lon: 23.8)
    private static let brussels = (lat: 50.85, lon: 4.35)
    /// About 16 km east of the Athens pin, outside its square seed.
    private static let village = (lat: 38.0, lon: 23.99)

    private func date(day offset: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: (offset + 329) * Self.day)
    }

    private func realRing(
        _ centre: (lat: Double, lon: Double), startedAt: Date, endedAt: Date? = nil,
        membership: HomeMembership? = nil
    ) -> TripClassifier.HomeRing {
        TripClassifier.HomeRing(
            latitude: centre.lat, longitude: centre.lon, radiusKm: 25,
            startedAt: startedAt, endedAt: endedAt, membership: membership)
    }

    private func temporaryRing(
        _ centre: (lat: Double, lon: Double), startedAt: Date, endedAt: Date? = nil,
        membership: HomeMembership? = nil
    ) -> TripClassifier.HomeRing {
        var ring = TripClassifier.HomeRing(HomeAnchor(
            id: UUID(), kind: .temporary, label: "Semester",
            latitude: centre.lat, longitude: centre.lon, radiusKm: 25,
            locality: nil, isoCountryCode: nil, startedAt: startedAt, endedAt: endedAt))
        ring.membership = membership
        return ring
    }

    private func matches(
        _ place: (lat: Double, lon: Double), at start: Date, _ rings: [TripClassifier.HomeRing]
    ) -> Bool {
        TripClassifier.matchesHome(
            stayStart: start, latitude: place.lat, longitude: place.lon, homes: rings)
    }

    // MARK: - The ring helper

    @Test("a ring built from a temporary anchor is marked temporary and does not claim prehistory, and attaching a shape keeps both marks")
    func anchorRingCarriesItsKind() {
        let temporary = temporaryRing(Self.brussels, startedAt: date(day: 10))
        #expect(temporary.isTemporary)
        #expect(!temporary.claimsPrehistory)
        let shaped = temporary.withShape(TemporaryHomeFixture.squareShape(id: 2, around: Self.brussels))
        #expect(shaped.isTemporary)
        #expect(!shaped.claimsPrehistory)
        #expect(shaped.membership != nil)

        let real = TripClassifier.HomeRing(HomeAnchor(
            id: UUID(), kind: .home, label: "Home",
            latitude: Self.athens.lat, longitude: Self.athens.lon, radiusKm: 25,
            locality: nil, isoCountryCode: nil, startedAt: date(day: 0), endedAt: nil))
        #expect(!real.isTemporary)
        #expect(real.claimsPrehistory)
        #expect(real.withShape(nil).claimsPrehistory)
    }

    // MARK: - Prehistory

    @Test("a stay that predates every home is never claimed by a temporary home, while a second real home at the same place would claim it")
    func temporaryRingNeverClaimsPrehistoryInMatchesHome() {
        let athens = realRing(Self.athens, startedAt: date(day: 1000))
        let semester = temporaryRing(
            Self.brussels, startedAt: date(day: 1500), endedAt: date(day: 1650))
        // An old holiday in the city the user later studies in.
        #expect(!matches(Self.brussels, at: date(day: 100), [athens, semester]))
        // The old Athens stay is still home through the real home's prehistory.
        #expect(matches(Self.athens, at: date(day: 100), [athens, semester]))
        // Control: the same place declared as a second real home claims it.
        let secondHome = realRing(Self.brussels, startedAt: date(day: 1500), endedAt: date(day: 1650))
        #expect(matches(Self.brussels, at: date(day: 100), [athens, secondHome]))
    }

    @Test("a group that predates every home is scored against the real homes only, never a temporary home")
    func temporaryRingNeverJoinsTheGatePrehistoryFallback() {
        let athensArea = HomeMembership(seed: TemporaryHomeFixture.squareShape(id: 1, around: Self.athens))
        let brusselsArea = HomeMembership(seed: TemporaryHomeFixture.squareShape(id: 2, around: Self.brussels))
        let athens = realRing(Self.athens, startedAt: date(day: 1000), membership: athensArea)
        let semester = temporaryRing(
            Self.brussels, startedAt: date(day: 1500), endedAt: date(day: 1650),
            membership: brusselsArea)
        #expect(TripClassifier.gateMemberships(
            stayStarts: [date(day: 100)], rings: [athens, semester]) == [athensArea])
        // Inside the semester both homes are in window, the semester's dated by its own dates.
        #expect(TripClassifier.gateMemberships(
            stayStarts: [date(day: 1600)], rings: [athens, semester])
            == [athensArea, brusselsArea.clamped(toEra: semester.era)])
    }

    @Test("a temporary home backdated before the real home does not stop an older stay at the real home from being home")
    func backdatedTemporaryRingKeepsRealHomePrehistory() {
        let athensArea = HomeMembership(seed: TemporaryHomeFixture.squareShape(id: 1, around: Self.athens))
        let brusselsArea = HomeMembership(seed: TemporaryHomeFixture.squareShape(id: 2, around: Self.brussels))
        let athens = realRing(Self.athens, startedAt: date(day: 1000), membership: athensArea)
        // Declared with a start date earlier than the real home's record.
        let semester = temporaryRing(Self.brussels, startedAt: date(day: 50), membership: brusselsArea)

        #expect(matches(Self.athens, at: date(day: 100), [athens, semester]))
        #expect(matches(Self.athens, at: date(day: 100), [semester, athens]))
        // The gate scores that old group against Athens too, not Brussels alone.
        let scored = TripClassifier.gateMemberships(
            stayStarts: [date(day: 100)], rings: [athens, semester])
        #expect(scored.contains(athensArea))
        // Inside its own dates the temporary home still claims its own place.
        #expect(matches(Self.brussels, at: date(day: 100), [athens, semester]))
    }

    @Test("with no current real home, an open-ended temporary home does not switch the prehistory fallback on")
    func openTemporaryRingIsNotACurrentHome() {
        let athensArea = HomeMembership(seed: TemporaryHomeFixture.squareShape(id: 1, around: Self.athens))
        let brusselsArea = HomeMembership(seed: TemporaryHomeFixture.squareShape(id: 2, around: Self.brussels))
        let endedAthens = realRing(
            Self.athens, startedAt: date(day: 1000), endedAt: date(day: 1400),
            membership: athensArea)
        let semester = temporaryRing(Self.brussels, startedAt: date(day: 1500), membership: brusselsArea)

        #expect(!matches(Self.athens, at: date(day: 100), [endedAthens, semester]))
        #expect(TripClassifier.gateMemberships(
            stayStarts: [date(day: 100)], rings: [endedAthens, semester]).isEmpty)
        // Control: a current real home turns the fallback on for the ended one too.
        let currentElsewhere = realRing((lat: 10, lon: 10), startedAt: date(day: 1400))
        #expect(matches(Self.athens, at: date(day: 100), [endedAthens, semester, currentElsewhere]))
    }

    /// `matchesHome` as it stood before temporary homes, copied verbatim.
    private static func matchesHomeBeforeTemporaryHomes(
        stayStart: Date, latitude: Double, longitude: Double, homes: [TripClassifier.HomeRing]
    ) -> Bool {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        func inRing(_ home: TripClassifier.HomeRing) -> Bool {
            if let membership = home.membership {
                return membership.contains(latitude: latitude, longitude: longitude,
                                           at: stayStart)
            }
            return CLLocation(latitude: home.latitude, longitude: home.longitude)
                .distance(from: location) / 1000.0 <= home.radiusKm
        }
        for home in homes {
            if let endedAt = home.endedAt, stayStart > endedAt { continue }
            if home.startedAt > stayStart { continue }
            if inRing(home) { return true }
        }
        let hasCurrentHome = homes.contains { $0.endedAt == nil }
        if hasCurrentHome, homes.allSatisfy({ stayStart < $0.startedAt }) {
            for home in homes {
                if let membership = home.membership {
                    if membership.contains(latitude: latitude, longitude: longitude,
                                           at: stayStart, includeTaught: false) {
                        return true
                    }
                } else if inRing(home) {
                    return true
                }
            }
        }
        return false
    }

    /// `gateMemberships` before temporary homes, with prehistory's taught includes dropped since.
    private static func gateMembershipsBeforeTemporaryHomes(
        stayStarts: [Date], rings: [TripClassifier.HomeRing]
    ) -> [HomeMembership] {
        var memberships: [HomeMembership] = []
        for ring in rings {
            guard let membership = ring.membership else { continue }
            let inWindow = stayStarts.contains { start in
                if let endedAt = ring.endedAt, start > endedAt { return false }
                return ring.startedAt <= start
            }
            if inWindow { memberships.append(membership) }
        }
        if memberships.isEmpty,
           rings.contains(where: { $0.endedAt == nil }),
           !stayStarts.isEmpty,
           stayStarts.allSatisfy({ start in rings.allSatisfy { start < $0.startedAt } }) {
            return rings.compactMap { $0.membership?.withoutTaughtIncludes() }
        }
        return memberships
    }

    @Test("with no temporary home, home matching and the gate's home list give exactly the answers they gave before")
    func noTemporaryRingIsBitIdenticalToBefore() {
        let athensArea = HomeMembership(seed: TemporaryHomeFixture.squareShape(id: 1, around: Self.athens))
        let brusselsArea = HomeMembership(
            seed: TemporaryHomeFixture.squareShape(id: 2, around: Self.brussels),
            includeDiscs: [(latitude: Self.village.lat, longitude: Self.village.lon, radiusKm: 1)])
        // Every combination of: no home, one current, one ended, ended plus
        // current, two current, shaped and unshaped.
        let ringSets: [[TripClassifier.HomeRing]] = [
            [],
            [realRing(Self.athens, startedAt: date(day: 1000))],
            [realRing(Self.athens, startedAt: date(day: 1000), endedAt: date(day: 2000))],
            [realRing(Self.athens, startedAt: date(day: 1000), endedAt: date(day: 2000)),
             realRing(Self.brussels, startedAt: date(day: 2000))],
            [realRing(Self.athens, startedAt: date(day: 1000), endedAt: date(day: 1500)),
             realRing(Self.brussels, startedAt: date(day: 2000))],
            [realRing(Self.athens, startedAt: date(day: 1000), membership: athensArea),
             realRing(Self.brussels, startedAt: date(day: 1500), membership: brusselsArea)],
            [realRing(Self.athens, startedAt: date(day: 1000), endedAt: date(day: 2000),
                      membership: athensArea),
             realRing(Self.brussels, startedAt: date(day: 2000), membership: brusselsArea)],
            [realRing(Self.athens, startedAt: date(day: 1000), endedAt: date(day: 1500),
                      membership: athensArea),
             realRing(Self.brussels, startedAt: date(day: 1200), endedAt: date(day: 1800))],
        ]
        let starts = [100.0, 999, 1000, 1001, 1500, 1750, 2000, 2001, 3000].map(date(day:))
        // Well inside or well outside every ring and shape, so no answer sits on an edge.
        let places = [Self.athens, Self.brussels, Self.village,
                      (lat: 38.1, lon: 23.8), (lat: 45.0, lon: 10.0)]
        for (index, rings) in ringSets.enumerated() {
            for start in starts {
                for place in places {
                    let new = TripClassifier.matchesHome(
                        stayStart: start, latitude: place.lat, longitude: place.lon, homes: rings)
                    let old = Self.matchesHomeBeforeTemporaryHomes(
                        stayStart: start, latitude: place.lat, longitude: place.lon, homes: rings)
                    #expect(new == old, "ring set \(index), start \(start), place \(place)")
                }
            }
            var groups: [[Date]] = [[]]
            for start in starts { groups.append([start]) }
            for (first, second) in zip(starts, starts.dropFirst()) { groups.append([first, second]) }
            groups.append([starts[0], starts[starts.count - 1]])
            for group in groups {
                let new = TripClassifier.gateMemberships(stayStarts: group, rings: rings)
                let old = Self.gateMembershipsBeforeTemporaryHomes(stayStarts: group, rings: rings)
                #expect(new == old, "ring set \(index), group \(group)")
                // No real home's membership is ever dated.
                #expect(new.allSatisfy { $0.era == nil }, "ring set \(index), group \(group)")
            }
        }
    }

    // MARK: - Dated membership

    @Test("a temporary home claims a stay at its place from its start through its end, both inclusive, and not a moment outside")
    func datedMembershipIsInclusiveAtBothEnds() {
        let athens = realRing(Self.athens, startedAt: date(day: 0))
        let start = date(day: 1500)
        let end = date(day: 1650)
        let rings = [athens, temporaryRing(Self.brussels, startedAt: start, endedAt: end)]

        #expect(!matches(Self.brussels, at: start.addingTimeInterval(-1), rings))
        #expect(matches(Self.brussels, at: start, rings))
        #expect(matches(Self.brussels, at: date(day: 1600), rings))
        #expect(matches(Self.brussels, at: end, rings))
        #expect(!matches(Self.brussels, at: end.addingTimeInterval(1), rings))
    }

    @Test("the gate hands out a temporary home's membership dated by its dates and a real home's undated, and a group older than every home gets the real home's alone")
    func gateDatesATemporaryRingsMembershipAndNotARealOnes() {
        let athensArea = HomeMembership(seed: TemporaryHomeFixture.squareShape(id: 1, around: Self.athens))
        let brusselsArea = HomeMembership(seed: TemporaryHomeFixture.squareShape(id: 2, around: Self.brussels))
        let athens = realRing(Self.athens, startedAt: date(day: 1000), membership: athensArea)
        let semester = temporaryRing(
            Self.brussels, startedAt: date(day: 1500), endedAt: date(day: 1650),
            membership: brusselsArea)

        let inside = TripClassifier.gateMemberships(
            stayStarts: [date(day: 1600)], rings: [athens, semester])
        #expect(inside.map(\.era) == [nil, DateInterval(start: date(day: 1500), end: date(day: 1650))])
        #expect(inside.map(\.seed) == [athensArea.seed, brusselsArea.seed])

        let prehistory = TripClassifier.gateMemberships(
            stayStarts: [date(day: 100)], rings: [athens, semester])
        #expect(prehistory == [athensArea])
        #expect(prehistory.allSatisfy { $0.era == nil })

        // An open-ended temporary home is dated from its start onwards.
        let open = temporaryRing(Self.brussels, startedAt: date(day: 1500), membership: brusselsArea)
        let dated = TripClassifier.gateMemberships(stayStarts: [date(day: 1600)], rings: [athens, open])
        #expect(dated.last?.era == DateInterval(start: date(day: 1500), end: .distantFuture))
    }

    @Test("a temporary home whose end date is still ahead claims a stay that starts today")
    func futureEndedTemporaryHomeClaimsTodaysStay() {
        let now = Date.now
        let rings = [
            realRing(Self.athens, startedAt: now.addingTimeInterval(-1000 * Self.day)),
            temporaryRing(Self.brussels, startedAt: now.addingTimeInterval(-30 * Self.day),
                          endedAt: now.addingTimeInterval(90 * Self.day)),
        ]
        #expect(matches(Self.brussels, at: now, rings))
    }

    private func makeStay(
        in ctx: ModelContext, at place: (lat: Double, lon: Double), startDay: Double,
        hours: Double = 6, category: StayCategory
    ) -> Stay {
        let start = date(day: startDay)
        let stay = Stay(
            startTime: start, endTime: start.addingTimeInterval(hours * 3600),
            centroidLatitude: place.lat, centroidLongitude: place.lon,
            h3IndexRes6: "T", pingCount: 2, distanceFromHomeKm: 0, pingIDs: [])
        stay.category = category
        ctx.insert(stay)
        return stay
    }

    @Test("the pre-filter stamps a new stay at a stored temporary home as home inside its dates only")
    func preFilterReadsStoredTemporaryHomes() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        ctx.insert(Home(label: "Athens", latitude: Self.athens.lat, longitude: Self.athens.lon,
                        radiusKm: 25, startedAt: date(day: 0)))
        ctx.insert(TemporaryHome(
            label: "Semester", latitude: Self.brussels.lat, longitude: Self.brussels.lon,
            startedAt: date(day: 1500), endedAt: date(day: 1650)))
        let before = makeStay(in: ctx, at: Self.brussels, startDay: 1400, category: .unclassified)
        let during = makeStay(in: ctx, at: Self.brussels, startDay: 1600, category: .unclassified)
        let after = makeStay(in: ctx, at: Self.brussels, startDay: 1700, category: .unclassified)
        let athens = makeStay(in: ctx, at: Self.athens, startDay: 1601, category: .unclassified)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.preFilterStays() == 2)
        #expect(await classifier.stayCategoryForTesting(before.id) == .unclassified)
        #expect(await classifier.stayCategoryForTesting(during.id) == .home)
        #expect(await classifier.stayCategoryForTesting(after.id) == .unclassified)
        // The real home keeps working during the semester.
        #expect(await classifier.stayCategoryForTesting(athens.id) == .home)
    }

    // MARK: - Distance

    @Test("a temporary home shortens a stay's distance from home only inside its dates")
    func temporaryWindowMeasuresOnlyInsideItsDates() {
        let windows = [
            StayClusterer.HomeWindow(
                latitude: Self.athens.lat, longitude: Self.athens.lon,
                startedAt: date(day: 0), endedAt: nil),
            StayClusterer.HomeWindow(
                latitude: Self.brussels.lat, longitude: Self.brussels.lon,
                startedAt: date(day: 1500), endedAt: date(day: 1650), isTemporary: true),
        ]
        func kmFromHome(atBrusselsOn day: Double) -> Double {
            StayClusterer.closestHomeDistanceKm(
                latitude: Self.brussels.lat, longitude: Self.brussels.lon,
                atTime: date(day: day), homes: windows)
        }
        #expect(kmFromHome(atBrusselsOn: 1600) < 1)
        // Outside the dates Brussels is measured from Athens, about 2,090 km away.
        #expect(kmFromHome(atBrusselsOn: 1400) > 2000)
        #expect(kmFromHome(atBrusselsOn: 1700) > 2000)
    }

    @Test("an open-ended temporary home is never the fallback home for a stay that predates every home")
    func temporaryWindowNeverServesTheFallback() {
        let athens = StayClusterer.HomeWindow(
            latitude: Self.athens.lat, longitude: Self.athens.lon,
            startedAt: date(day: 1000), endedAt: nil)
        let openSemester = StayClusterer.HomeWindow(
            latitude: Self.brussels.lat, longitude: Self.brussels.lon,
            startedAt: date(day: 1500), endedAt: nil, isTemporary: true)
        // Before both: the fallback measures from the current real home.
        let old = StayClusterer.closestHomeDistanceKm(
            latitude: Self.brussels.lat, longitude: Self.brussels.lon,
            atTime: date(day: 100), homes: [athens, openSemester])
        #expect(old > 2000)
        // With no real home there is no fallback measurement at all.
        #expect(StayClusterer.closestHomeDistanceKm(
            latitude: Self.brussels.lat, longitude: Self.brussels.lon,
            atTime: date(day: 100), homes: [openSemester]) == Double.greatestFiniteMagnitude)
        // The same window as a real home is the fallback, as before.
        let realTwin = StayClusterer.HomeWindow(
            latitude: Self.brussels.lat, longitude: Self.brussels.lon,
            startedAt: date(day: 1500), endedAt: nil)
        #expect(StayClusterer.closestHomeDistanceKm(
            latitude: Self.brussels.lat, longitude: Self.brussels.lon,
            atTime: date(day: 100), homes: [athens, realTwin]) < 1)
    }

    // MARK: - Welcome Home

    @Test("arriving at a temporary home is not a homecoming, arriving at the real home is, even when temporary homes cannot be read")
    func welcomeHomeSeedIsRealHomesOnly() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        ctx.insert(Home(label: "Athens", latitude: Self.athens.lat, longitude: Self.athens.lon,
                        radiusKm: 25, startedAt: date(day: 0)))
        // Active now: started in the past, no end.
        ctx.insert(TemporaryHome(
            label: "Semester", latitude: Self.brussels.lat, longitude: Self.brussels.lon,
            startedAt: date(day: 1)))
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.athens.lat, longitude: Self.athens.lon,
            shape: TemporaryHomeFixture.squareShape(id: 1, around: Self.athens))
        await classifier.primeShapeForTesting(
            latitude: Self.brussels.lat, longitude: Self.brussels.lon,
            shape: TemporaryHomeFixture.squareShape(id: 2, around: Self.brussels))

        #expect(try await classifier.currentHomeSeedCovers(
            latitude: Self.athens.lat, longitude: Self.athens.lon))
        #expect(try await classifier.currentHomeSeedCovers(
            latitude: Self.brussels.lat, longitude: Self.brussels.lon) == false)
        // The temporary home is still home area for classification right now.
        #expect(await classifier.currentMembershipCovers(
            latitude: Self.brussels.lat, longitude: Self.brussels.lon))

        classifier.failTemporaryHomeReadForTesting = true
        defer { classifier.failTemporaryHomeReadForTesting = false }
        #expect(try await classifier.currentHomeSeedCovers(
            latitude: Self.athens.lat, longitude: Self.athens.lon))
    }

    // MARK: - Orbit

    /// Three days of: home overnight, five hours at the village, home again.
    /// The village stays are tripless destinations; a fourth village stay
    /// on day `firstDay + 3` is left unclassified for the pre-filter.
    private func seedThreeSameDayReturns(
        in ctx: ModelContext, from place: (lat: Double, lon: Double), firstDay: Double
    ) -> Stay {
        for offset in 0..<4 {
            let dayStart = firstDay + Double(offset)
            _ = makeStay(in: ctx, at: place, startDay: dayStart, hours: 8, category: .home)
            _ = makeStay(in: ctx, at: place, startDay: dayStart + 17.0 / 24, hours: 6.5,
                         category: .home)
        }
        for offset in 0..<3 {
            _ = makeStay(in: ctx, at: Self.village, startDay: firstDay + Double(offset) + 10.0 / 24,
                         hours: 5, category: .destination)
        }
        return makeStay(in: ctx, at: Self.village, startDay: firstDay + 3 + 10.0 / 24,
                        hours: 5, category: .unclassified)
    }

    @Test("three same-day returns from one nearby place teach a real home that place, and the fourth visit there is home")
    func realHomeStillLearnsAnOrbit() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let home = Home(label: "Athens", latitude: Self.athens.lat, longitude: Self.athens.lon,
                        radiusKm: 25, startedAt: date(day: 0))
        ctx.insert(home)
        let fourth = seedThreeSameDayReturns(in: ctx, from: Self.athens, firstDay: 100)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.athens.lat, longitude: Self.athens.lon,
            shape: TemporaryHomeFixture.squareShape(id: 1, around: Self.athens))
        let orbits = await classifier.primedOrbitsForTesting()
        #expect(orbits[home.id.uuidString]?.count == 1)
        #expect(await classifier.learnedPlaces().map(\.homeID) == [home.id])

        #expect(await classifier.preFilterStays() == 1)
        #expect(await classifier.stayCategoryForTesting(fourth.id) == .home)
    }

    @Test("the same three same-day returns teach a temporary home nothing, so the fourth visit there is not home")
    func temporaryHomeLearnsNoOrbit() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // The real home is elsewhere; the semester is at the Athens fixture pin.
        let realHome = Home(label: "Brussels", latitude: Self.brussels.lat,
                            longitude: Self.brussels.lon, radiusKm: 25, startedAt: date(day: 0))
        ctx.insert(realHome)
        let semester = TemporaryHome(
            label: "Semester", latitude: Self.athens.lat, longitude: Self.athens.lon,
            startedAt: date(day: 90), endedAt: date(day: 200))
        ctx.insert(semester)
        let fourth = seedThreeSameDayReturns(in: ctx, from: Self.athens, firstDay: 100)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.athens.lat, longitude: Self.athens.lon,
            shape: TemporaryHomeFixture.squareShape(id: 1, around: Self.athens))
        await classifier.primeShapeForTesting(
            latitude: Self.brussels.lat, longitude: Self.brussels.lon,
            shape: TemporaryHomeFixture.squareShape(id: 2, around: Self.brussels))
        let orbits = await classifier.primedOrbitsForTesting()
        #expect((orbits[semester.id.uuidString] ?? []).isEmpty)
        #expect((orbits[realHome.id.uuidString] ?? []).isEmpty)
        #expect(await classifier.learnedPlaces().isEmpty)
        // Only the real home's evidence was derived; none ran for the temporary home.
        #expect(await classifier.orbitDerivationCountForTesting == 1)

        // The fourth village visit is judged on its own: not home.
        #expect(await classifier.preFilterStays() == 0)
        #expect(await classifier.stayCategoryForTesting(fourth.id) == .unclassified)
    }

    @Test("a place the user taught a temporary home is home inside its dates and not after it ends")
    func taughtIncludeIsHonouredInsideTheDates() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        ctx.insert(Home(label: "Brussels", latitude: Self.brussels.lat,
                        longitude: Self.brussels.lon, radiusKm: 25, startedAt: date(day: 0)))
        let semester = TemporaryHome(
            label: "Semester", latitude: Self.athens.lat, longitude: Self.athens.lon,
            startedAt: date(day: 90), endedAt: date(day: 200))
        ctx.insert(semester)
        ctx.insert(HomeAreaOverride(
            kind: .include, centerLatitude: Self.village.lat,
            centerLongitude: Self.village.lon, radiusKm: 1, homeID: semester.id))
        let during = makeStay(in: ctx, at: Self.village, startDay: 150, category: .unclassified)
        let after = makeStay(in: ctx, at: Self.village, startDay: 250, category: .unclassified)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.athens.lat, longitude: Self.athens.lon,
            shape: TemporaryHomeFixture.squareShape(id: 1, around: Self.athens))
        await classifier.primeShapeForTesting(
            latitude: Self.brussels.lat, longitude: Self.brussels.lon,
            shape: TemporaryHomeFixture.squareShape(id: 2, around: Self.brussels))

        #expect(await classifier.preFilterStays() == 1)
        #expect(await classifier.stayCategoryForTesting(during.id) == .home)
        #expect(await classifier.stayCategoryForTesting(after.id) == .unclassified)
    }
}

// MARK: - A backdated temporary home and the real home's prehistory

extension TemporaryHomeClassifierTests {
    @Test("a stay at the real home before its record, inside a backdated temporary home's dates, is measured from the real home, and one at the base from the base")
    func backdatedTemporaryWindowKeepsPrehistoryDistance() {
        let athens = StayClusterer.HomeWindow(
            latitude: Self.athens.lat, longitude: Self.athens.lon,
            startedAt: date(day: 1000), endedAt: nil)
        let semester = StayClusterer.HomeWindow(
            latitude: Self.brussels.lat, longitude: Self.brussels.lon,
            startedAt: date(day: 50), endedAt: date(day: 200), isTemporary: true)
        func km(at place: (lat: Double, lon: Double), day: Double) -> Double {
            StayClusterer.closestHomeDistanceKm(
                latitude: place.lat, longitude: place.lon,
                atTime: date(day: day), homes: [athens, semester])
        }
        #expect(km(at: Self.athens, day: 100) < 1)
        #expect(km(at: Self.brussels, day: 100) < 1)
        // Once the real home's record covers the date, the dates decide alone.
        #expect(km(at: Self.brussels, day: 1100) > 2000)
    }
}
