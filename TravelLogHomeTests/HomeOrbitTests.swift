//
//  HomeOrbitTests.swift
//  TravelLogTests
//
//  Checks for the home-orbit expansion engine.
//  Synthetic fixtures cover repeated same-day away visits, corridor dwell
//  refusal (clause d), overnight stays (clause b), and transit-only runs
//  (clause c), plus the
//  structural invariants: containing-window healing, 12-month expiry,
//  link-radius plateau, clustering determinism, D* immutability under discs,
//  and exclude-beats-orbit-but-never-seed.
//
//  All engine calls are pure and synchronous; no store, no actors. UTC-pinned
//  dates (the ClassifierHeuristicsTests convention) so nothing is
//  runner-timezone-flaky.
//

import Foundation
import Testing
@testable import TravelLog

struct HomeOrbitTests {

    // MARK: - Synthetic seed and away-place geometry

    /// A synthetic urban-centre seed: a ~10×10 km square around "home".
    /// Flat rings, [x0, y0, x1, y1, …], the WKBPolygon layout.
    private static let homeLat = 38.0126, homeLon = 23.7128
    private static func squareSeed() -> HomeShape {
        let half = 0.05   // ~5 km in lat, ~4.4 km in lon at 38°
        let ring: [Double] = [
            Self.homeLon - half, Self.homeLat - half,
            Self.homeLon + half, Self.homeLat - half,
            Self.homeLon + half, Self.homeLat + half,
            Self.homeLon - half, Self.homeLat + half,
            Self.homeLon - half, Self.homeLat - half,
        ]
        return HomeShape.urbanCentre(id: 1, name: "Square", areaKm2: 97,
                                     rings: [[ring]],
                                     centreLatitude: Self.homeLat,
                                     centreLongitude: Self.homeLon)
    }

    private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }

    private var visitDays: [Date] {
        [utc(2024, 5, 27), utc(2024, 6, 27), utc(2024, 7, 25),
         utc(2024, 8, 25), utc(2024, 9, 24), utc(2024, 10, 25)]
    }

    private func at(_ day: Date, hour: Int, minute: Int = 0) -> Date {
        day.addingTimeInterval(Double(hour * 3_600 + minute * 60))
    }

    private func obs(_ id: Int, _ start: Date, hours: Double,
                     lat: Double, lon: Double,
                     transit: Bool = false, live: Bool = true) -> HomeOrbit.StayObservation {
        // Deterministic UUID from the integer so shuffled-input tests can
        // compare identity across runs.
        let uuid = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!
        return .init(id: uuid, start: start, end: start.addingTimeInterval(hours * 3600),
                     latitude: lat, longitude: lon, isTransitNode: transit, isLive: live)
    }

    /// Home stay helper — inside the square seed.
    private func home(_ id: Int, _ start: Date, hours: Double = 12) -> HomeOrbit.StayObservation {
        obs(id, start, hours: hours, lat: Self.homeLat, lon: Self.homeLon)
    }

    // Away places outside the seed, at urban-centre scale.
    private static let village = (lat: 37.76498, lon: 24.0765)
    private static let corridor = (lat: 38.0126, lon: 23.9128)
    private static let island = (lat: 37.4405, lon: 24.9301)

    // MARK: - Repeated same-day qualifying visits

    @Test("three monthly same-day 5h visits outside the seed admit a disc whose validity covers ALL THREE visits (containing window)")
    func monthlySameDayVisitsExpandAndHealRetroactively() {
        let seed = Self.squareSeed()
        var stays: [HomeOrbit.StayObservation] = []
        var id = 0
        var visits: [Date] = []
        for day in visitDays.suffix(3) {
            let visit = at(day, hour: 11)
            visits.append(visit)
            stays.append(home(id, at(day, hour: 0), hours: 10)); id += 1
            stays.append(obs(id, visit, hours: 5.3, lat: Self.village.lat, lon: Self.village.lon)); id += 1
            stays.append(home(id, at(day, hour: 18), hours: 12)); id += 1
        }
        let audits = HomeOrbit.deriveDiscs(observations: stays, seed: seed)
        let admitted = audits.compactMap(\.disc)
        #expect(admitted.count == 1)
        let disc = try! #require(admitted.first)
        #expect(disc.returnTimes.count == 3)
        // Containing-window rule: the FIRST visit — before the pattern
        // existed — is inside the validity window. This is a hard
        // requirement.
        for v in visits {
            #expect(disc.isValid(at: v), "visit \(v) not healed")
        }
        // And it expires: 13 months after the last return it no longer applies.
        #expect(!disc.isValid(at: utc(2025, 12, 1)))
    }

    @Test("two visits do not admit; the third does (K = 3, flat)")
    func kIsFlatThree() {
        let seed = Self.squareSeed()
        func staysFor(days: [Date]) -> [HomeOrbit.StayObservation] {
            var out: [HomeOrbit.StayObservation] = []
            var id = 0
            for day in days {
                out.append(home(id, at(day, hour: 0), hours: 10)); id += 1
                out.append(obs(id, at(day, hour: 11), hours: 5,
                               lat: Self.village.lat, lon: Self.village.lon)); id += 1
                out.append(home(id, at(day, hour: 18), hours: 12)); id += 1
            }
            return out
        }
        #expect(HomeOrbit.deriveDiscs(observations: staysFor(days: Array(visitDays[3..<5])), seed: seed)
            .compactMap(\.disc).isEmpty)
        #expect(HomeOrbit.deriveDiscs(observations: staysFor(days: Array(visitDays.suffix(3))), seed: seed)
            .compactMap(\.disc).count == 1)
    }

    // MARK: - Clause (d): the corridor, red/green

    @Test("seven same-day drive-bys with 4-minute dwell admit NOTHING — and the same visits with 40-minute dwell admit (clause d red/green)")
    func dwellFloorKillsCorridors() {
        let seed = Self.squareSeed()
        func corridorStays(dwellMinutes: Double) -> [HomeOrbit.StayObservation] {
            var out: [HomeOrbit.StayObservation] = []
            var id = 0
            for week in 0..<7 {
                let day = utc(2024, 7, 15, 9).addingTimeInterval(Double(week) * 7 * 86_400)
                out.append(home(id, utc(2024, 7, 15, 0).addingTimeInterval(Double(week) * 7 * 86_400), hours: 8)); id += 1
                out.append(obs(id, day, hours: dwellMinutes / 60,
                               lat: Self.corridor.lat, lon: Self.corridor.lon)); id += 1
                out.append(home(id, utc(2024, 7, 15, 12).addingTimeInterval(Double(week) * 7 * 86_400), hours: 12)); id += 1
            }
            return out
        }
        // RED: without enough dwell, 7 visits — more than K — admit nothing.
        let red = HomeOrbit.deriveDiscs(
            observations: corridorStays(dwellMinutes: 4), seed: seed)
        #expect(red.compactMap(\.disc).isEmpty)
        #expect(red.contains { $0.qualifyingReturnTimes.isEmpty && $0.stayCount == 7 })
        // GREEN: identical pattern with real dwell admits.
        let green = HomeOrbit.deriveDiscs(
            observations: corridorStays(dwellMinutes: 40), seed: seed)
        #expect(green.compactMap(\.disc).count == 1)
    }

    // MARK: - Clause (b): overnight holidays never qualify

    @Test("seven overnight stays outside the seed yield zero qualifying returns; no same-day return exists (clause b)")
    func overnightHolidaysNeverQualify() {
        let seed = Self.squareSeed()
        var stays: [HomeOrbit.StayObservation] = []
        var id = 0
        for week in 0..<7 {
            let friday = utc(2024, 10, 18, 18).addingTimeInterval(Double(week) * 3 * 86_400)   // varied dates, same shape
            stays.append(home(id, utc(2024, 10, 18, 0).addingTimeInterval(Double(week) * 3 * 86_400), hours: 10)); id += 1
            stays.append(obs(id, friday, hours: 40,
                             lat: Self.island.lat, lon: Self.island.lon)); id += 1
            stays.append(home(id, friday.addingTimeInterval(48 * 3600), hours: 12)); id += 1
        }
        let audits = HomeOrbit.deriveDiscs(observations: stays, seed: seed)
        #expect(audits.compactMap(\.disc).isEmpty)
        #expect(audits.allSatisfy { $0.qualifyingReturnTimes.isEmpty })
    }

    // MARK: - Clause (c) + neutrality: transit nodes

    @Test("transit-node stays never anchor clusters, never satisfy reach, and a transit-only run qualifies nothing (clause c)")
    func transitNodesAreNeutral() {
        let seed = Self.squareSeed()
        var stays: [HomeOrbit.StayObservation] = []
        var id = 0
        for day in visitDays.suffix(3) {
            stays.append(home(id, at(day, hour: 0), hours: 8)); id += 1
            stays.append(obs(id, at(day, hour: 9), hours: 2,
                             lat: Self.corridor.lat, lon: Self.corridor.lon,
                             transit: true)); id += 1
            stays.append(home(id, at(day, hour: 12), hours: 12)); id += 1
        }
        let audits = HomeOrbit.deriveDiscs(observations: stays, seed: seed)
        // The airport stays don't even form a candidate cluster.
        #expect(audits.isEmpty)

        // Two real same-day village visits form a cluster one return short of
        // K. Three transit-only runs to a node at the same spot, each dwelling
        // two hours and returning home the same day, would lift it to five.
        var clustered: [HomeOrbit.StayObservation] = []
        id = 100
        for day in visitDays.prefix(2) {
            clustered.append(home(id, at(day, hour: 0), hours: 10)); id += 1
            clustered.append(obs(id, at(day, hour: 11), hours: 5,
                                 lat: Self.village.lat, lon: Self.village.lon)); id += 1
            clustered.append(home(id, at(day, hour: 18), hours: 12)); id += 1
        }
        for day in visitDays[2..<5] {
            clustered.append(home(id, at(day, hour: 0), hours: 8)); id += 1
            clustered.append(obs(id, at(day, hour: 9), hours: 2,
                                 lat: Self.village.lat, lon: Self.village.lon,
                                 transit: true)); id += 1
            clustered.append(home(id, at(day, hour: 12), hours: 12)); id += 1
        }
        let village = HomeOrbit.deriveDiscs(observations: clustered, seed: seed)
        #expect(village.count == 1)
        #expect(village.first?.stayCount == 2)
        #expect(village.first?.qualifyingReturnTimes.count == 2)
        #expect(village.compactMap(\.disc).isEmpty)
    }

    // MARK: - Imported evidence never anchors

    @Test("photo-import stays supply no expansion evidence (live-lane only)")
    func importedStaysNeverAnchor() {
        let seed = Self.squareSeed()
        var stays: [HomeOrbit.StayObservation] = []
        var id = 0
        for day in visitDays.suffix(3) {
            stays.append(home(id, at(day, hour: 0), hours: 8)); id += 1
            stays.append(obs(id, at(day, hour: 11), hours: 5,
                             lat: Self.village.lat, lon: Self.village.lon,
                             live: false)); id += 1
            stays.append(home(id, at(day, hour: 18), hours: 12)); id += 1
        }
        #expect(HomeOrbit.deriveDiscs(observations: stays, seed: seed).isEmpty)
    }

    // MARK: - Clause (b): both home brackets must be witnessed

    /// One month's same-day pattern at the village: a home stay ending at
    /// `leaveHome`, a visit from `arrive` for `hours`, and a home stay
    /// starting at `returnHome` (nil leaves the visit open).
    private func villageMonth(
        _ id: inout Int, leaveHome: Date, arrive: Date, hours: Double,
        returnHome: Date?, homeLive: Bool = true
    ) -> [HomeOrbit.StayObservation] {
        var out = [obs(id, leaveHome.addingTimeInterval(-8 * 3600), hours: 8,
                       lat: Self.homeLat, lon: Self.homeLon, live: homeLive)]
        id += 1
        out.append(obs(id, arrive, hours: hours,
                       lat: Self.village.lat, lon: Self.village.lon))
        id += 1
        if let returnHome {
            out.append(obs(id, returnHome, hours: 12,
                           lat: Self.homeLat, lon: Self.homeLon, live: homeLive))
            id += 1
        }
        return out
    }

    private func sameDayVisits(
        _ days: [Date], homeLive: Bool = true
    ) -> [HomeOrbit.StayObservation] {
        var id = 0
        return days.flatMap { day in
            villageMonth(&id, leaveHome: at(day, hour: 10),
                         arrive: at(day, hour: 11), hours: 5,
                         returnHome: at(day, hour: 18), homeLive: homeLive)
        }
    }

    @Test("isolated one-hour visits with no home observation never qualify")
    func isolatedVisitsNeverQualify() {
        let stays = visitDays.suffix(3).enumerated().map { index, day in
            obs(index, at(day, hour: 11), hours: 1,
                lat: Self.village.lat, lon: Self.village.lon)
        }
        let audits = HomeOrbit.deriveDiscs(observations: stays, seed: Self.squareSeed())
        #expect(audits.count == 1)
        #expect(audits.allSatisfy { $0.qualifyingReturnTimes.isEmpty && $0.disc == nil })
    }

    @Test("a short visit whose next home observation comes days later is no same-day return")
    func lateHomeObservationNeverQualifies() {
        var id = 0
        let stays = visitDays.suffix(3).flatMap { day in
            villageMonth(&id, leaveHome: at(day, hour: 10),
                         arrive: at(day, hour: 11), hours: 1,
                         returnHome: at(day.addingTimeInterval(3 * 86_400), hour: 12))
        }
        let audits = HomeOrbit.deriveDiscs(observations: stays, seed: Self.squareSeed())
        #expect(audits.allSatisfy { $0.qualifyingReturnTimes.isEmpty && $0.disc == nil })
    }

    @Test("a visit still open at the end of input is not a return; the witnessed arrival home is")
    func openVisitWaitsForItsReturn() throws {
        var id = 0
        var stays = visitDays[3..<5].flatMap { day in
            villageMonth(&id, leaveHome: at(day, hour: 10),
                         arrive: at(day, hour: 11), hours: 5,
                         returnHome: at(day, hour: 18))
        }
        stays += villageMonth(&id, leaveHome: utc(2024, 10, 25, 10),
                              arrive: utc(2024, 10, 25, 11), hours: 5, returnHome: nil)
        let open = HomeOrbit.deriveDiscs(observations: stays, seed: Self.squareSeed())
        #expect(open.compactMap(\.disc).isEmpty)
        #expect(open.map(\.qualifyingReturnTimes.count) == [2])

        stays.append(obs(id, utc(2024, 10, 25, 18), hours: 12,
                         lat: Self.homeLat, lon: Self.homeLon))
        let closed = HomeOrbit.deriveDiscs(observations: stays, seed: Self.squareSeed())
        let disc = try #require(closed.compactMap(\.disc).first)
        #expect(disc.returnTimes == visitDays.suffix(3).map { at($0, hour: 18) })
        #expect(disc.isValid(at: utc(2024, 8, 25, 11)), "the first visit is still healed")
    }

    @Test("a run after an unknown gap from the last home stay has no witnessed departure")
    func leadingUnknownGapNeverQualifies() {
        var id = 0
        let stays = visitDays.suffix(3).flatMap { day in
            villageMonth(&id, leaveHome: at(day.addingTimeInterval(-12 * 86_400), hour: 10),
                         arrive: at(day, hour: 11), hours: 5,
                         returnHome: at(day, hour: 18))
        }
        let audits = HomeOrbit.deriveDiscs(observations: stays, seed: Self.squareSeed())
        #expect(audits.allSatisfy { $0.qualifyingReturnTimes.isEmpty && $0.disc == nil })
    }

    @Test("imported home observations cannot witness a live visit's brackets")
    func importedBracketsNeverWitness() {
        let audits = HomeOrbit.deriveDiscs(
            observations: sameDayVisits(Array(visitDays.suffix(3)), homeLive: false), seed: Self.squareSeed())
        #expect(audits.count == 1)
        #expect(audits.allSatisfy { $0.qualifyingReturnTimes.isEmpty && $0.disc == nil })
        #expect(HomeOrbit.deriveDiscs(observations: sameDayVisits(Array(visitDays.suffix(3))),
                                      seed: Self.squareSeed()).compactMap(\.disc).count == 1)
    }

    @Test("an away observation running past the alleged home arrival is ambiguous and never counts")
    func overlappingReturnNeverQualifies() {
        var id = 0
        let stays = visitDays.suffix(3).flatMap { day in
            // The visit runs 11:00-17:00, the home stay claims 16:00.
            villageMonth(&id, leaveHome: at(day, hour: 10),
                         arrive: at(day, hour: 11), hours: 6,
                         returnHome: at(day, hour: 16))
        }
        let audits = HomeOrbit.deriveDiscs(observations: stays, seed: Self.squareSeed())
        #expect(audits.allSatisfy { $0.qualifyingReturnTimes.isEmpty && $0.disc == nil })
    }

    @Test("a home stay with the same interval as the visit never certifies it, whatever the input order",
          arguments: [false, true])
    func equalTimeBracketIsAmbiguous(homeFirst: Bool) {
        var stays: [HomeOrbit.StayObservation] = []
        for (index, day) in visitDays.suffix(3).enumerated() {
            let base = index * 10
            let visit = at(day, hour: 11)
            stays.append(home(base, at(day, hour: 0), hours: 10))
            // Identity order decides which of the twins-in-time sorts first.
            stays.append(obs(base + (homeFirst ? 2 : 1), visit, hours: 5,
                             lat: Self.village.lat, lon: Self.village.lon))
            stays.append(obs(base + (homeFirst ? 1 : 2), visit, hours: 5,
                             lat: Self.homeLat, lon: Self.homeLon))
            stays.append(home(base + 3, at(day, hour: 18)))
        }
        for input in [stays, stays.reversed()] {
            let audits = HomeOrbit.deriveDiscs(observations: input, seed: Self.squareSeed())
            #expect(audits.allSatisfy { $0.qualifyingReturnTimes.isEmpty && $0.disc == nil })
        }
    }

    @Test("clause (b) boundaries: home within exactly 12 h, departure support within exactly 7 days",
          arguments: [0.0, 1.0])
    func witnessedBracketBoundaries(overshootSeconds: Double) {
        var id = 0
        let lateReturn = visitDays.suffix(3).flatMap { day in
            villageMonth(&id, leaveHome: at(day, hour: 10),
                         arrive: at(day, hour: 11), hours: 1,
                         returnHome: at(day, hour: 23)
                            .addingTimeInterval(overshootSeconds))
        }
        id = 0
        let lateDeparture = visitDays.suffix(3).flatMap { day in
            let arrive = at(day, hour: 11)
            return villageMonth(
                &id,
                leaveHome: arrive.addingTimeInterval(
                    -PresenceEvidence.unknownGapSeconds - overshootSeconds),
                arrive: arrive, hours: 1, returnHome: at(day, hour: 14))
        }
        let expected = overshootSeconds == 0 ? 1 : 0
        for stays in [lateReturn, lateDeparture] {
            let audits = HomeOrbit.deriveDiscs(observations: stays, seed: Self.squareSeed())
            #expect(audits.compactMap(\.disc).count == expected)
        }
    }

    // MARK: - Link-radius plateau + determinism

    @Test("the admitted set is identical across link radii 0.5 to 2.0 km")
    func linkRadiusPlateau() {
        var stays: [HomeOrbit.StayObservation] = []
        var id = 0
        for day in visitDays.suffix(3) {
            stays.append(home(id, at(day, hour: 0), hours: 8)); id += 1
            stays.append(obs(id, at(day, hour: 11), hours: 5,
                             lat: Self.village.lat, lon: Self.village.lon)); id += 1
            stays.append(home(id, at(day, hour: 18), hours: 12)); id += 1
        }
        let sets = [0.5, 1.0, 2.0].map { link in
            HomeOrbit.clusters(from: stays, linkRadiusKm: link)
                .map { (String(format: "%.3f", $0.latitude), String(format: "%.3f", $0.longitude)) }
        }
        #expect(sets[0].elementsEqual(sets[1], by: ==))
        #expect(sets[1].elementsEqual(sets[2], by: ==))
    }

    @Test("clustering is order-independent: shuffled input yields identical clusters and discs")
    func clusteringIsDeterministic() {
        let seed = Self.squareSeed()
        var stays: [HomeOrbit.StayObservation] = []
        var id = 0
        for day in visitDays.suffix(3) {
            stays.append(home(id, at(day, hour: 0), hours: 8)); id += 1
            stays.append(obs(id, at(day, hour: 11), hours: 5,
                             lat: Self.village.lat, lon: Self.village.lon)); id += 1
            stays.append(obs(id, at(day, hour: 16, minute: 30), hours: 1,
                             lat: Self.village.lat + 0.004, lon: Self.village.lon)); id += 1
            stays.append(home(id, at(day, hour: 18), hours: 12)); id += 1
        }
        let a = HomeOrbit.deriveDiscs(observations: stays, seed: seed)
        let b = HomeOrbit.deriveDiscs(observations: stays.reversed(), seed: seed)
        #expect(a.compactMap(\.disc) == b.compactMap(\.disc))
    }

    @Test("identical UUID twins preserve single-row evidence without doubling dwell", arguments: [20.0, 40.0])
    func identicalUUIDTwinsPreserveEvidence(dwellMinutes: Double) {
        var stays: [HomeOrbit.StayObservation] = []
        for (index, day) in visitDays.suffix(3).enumerated() {
            stays.append(home(index * 3, at(day, hour: 0), hours: 8))
            stays.append(obs(index * 3 + 1, at(day, hour: 11),
                             hours: dwellMinutes / 60,
                             lat: Self.village.lat, lon: Self.village.lon))
            stays.append(home(index * 3 + 2, at(day, hour: 18)))
        }
        let expected = HomeOrbit.deriveDiscs(observations: stays, seed: Self.squareSeed())
        #expect(expected.count == 1)
        #expect(expected.compactMap(\.disc).count == (dwellMinutes >= 30 ? 1 : 0))
        for input in [stays + stays, Array((stays + stays).reversed())] {
            let actual = HomeOrbit.deriveDiscs(observations: input, seed: Self.squareSeed())
            #expect(actual.compactMap(\.disc) == expected.compactMap(\.disc))
            #expect(actual.map(\.stayCount) == [3])
            #expect(actual.map(\.qualifyingReturnTimes) == expected.map(\.qualifyingReturnTimes))
            #expect(actual.map(\.centerLatitude) == expected.map(\.centerLatitude))
            #expect(actual.map(\.centerLongitude) == expected.map(\.centerLongitude))
            #expect(actual.map(\.radiusKm) == expected.map(\.radiusKm))
        }
    }

    @Test("disagreeing UUID twins select one whole observation deterministically",
          arguments: ["start", "dwell", "latitude", "longitude", "transit", "live"])
    func disagreeingUUIDTwinsSelectCanonicalObservation(tieBreak: String) {
        var stays: [HomeOrbit.StayObservation] = []
        var twins: [HomeOrbit.StayObservation] = []
        for (index, day) in visitDays.suffix(3).enumerated() {
            let start = at(day, hour: 11)
            stays.append(home(index * 3, at(day, hour: 0), hours: 8))
            stays.append(obs(index * 3 + 1, start, hours: 2.0 / 3,
                             lat: Self.village.lat, lon: Self.village.lon))
            stays.append(home(index * 3 + 2, at(day, hour: 18)))
            // Earlier start wins even over a longer dwell. Each remaining
            // case ties every preceding field in the canonical ordering.
            twins.append(obs(index * 3 + 1,
                             start.addingTimeInterval(tieBreak == "start" ? 60 : 0),
                             hours: tieBreak == "start" ? 24 : (tieBreak == "dwell" ? 1.0 / 3 : 2.0 / 3),
                             lat: Self.village.lat + (tieBreak == "latitude" ? 0.1 : 0),
                             lon: Self.village.lon + (tieBreak == "longitude" ? 0.1 : 0),
                             transit: tieBreak == "transit", live: tieBreak != "live"))
        }
        let expected = HomeOrbit.deriveDiscs(observations: stays, seed: Self.squareSeed())
        #expect(expected.compactMap(\.disc).count == 1)
        #expect(expected.first?.qualifyingReturnTimes.count == 3)
        for input in [stays + twins, Array((stays + twins).reversed())] {
            let actual = HomeOrbit.deriveDiscs(observations: input, seed: Self.squareSeed())
            #expect(actual.compactMap(\.disc) == expected.compactMap(\.disc))
            #expect(actual.map(\.stayCount) == [3])
            #expect(actual.map(\.qualifyingReturnTimes) == expected.map(\.qualifyingReturnTimes))
            #expect(actual.map(\.centerLatitude) == expected.map(\.centerLatitude))
            #expect(actual.map(\.centerLongitude) == expected.map(\.centerLongitude))
            #expect(actual.map(\.radiusKm) == expected.map(\.radiusKm))
        }
    }

    @Test("dense groups retain every member when joined by a single-linkage bridge", arguments: [false, true])
    func denseGroupsJoinThroughBridge(reverseInput: Bool) throws {
        let start = utc(2025, 1, 1)
        func point(_ id: Int, latitude: Double) -> HomeOrbit.StayObservation {
            obs(id, start.addingTimeInterval(Double(id) * 3600), hours: 0.5,
                lat: latitude, lon: 0)
        }
        // The dense endpoints are ~3.55 km apart. Three later observations
        // bridge them with ~0.89 km links, including across grid boundaries.
        let left = (0..<8).map { point($0, latitude: 38) }
        let right = (8..<16).map { point($0, latitude: 38.032) }
        #expect(HomeOrbit.clusters(from: left + right, linkRadiusKm: 1).count == 2)
        let bridge = [point(16, latitude: 38.008),
                      point(17, latitude: 38.016),
                      point(18, latitude: 38.024)]
        let connected = left + right + bridge
        let isolated = point(19, latitude: 38.08)
        let observations = connected + [isolated]
        let input = reverseInput ? Array(observations.reversed()) : observations
        let clusters = HomeOrbit.clusters(from: input, linkRadiusKm: 1)

        #expect(clusters.count == 2)
        let joined = try #require(clusters.first { $0.members.count > 1 })
        #expect(joined.members.map(\.id) == connected.map(\.id))
        #expect(abs(joined.latitude - 38.016) < 1e-10)
        #expect(joined.longitude == 0)
        // The member p90 is ~1.78 km, above the floor: redundant endpoint
        // observations must still participate in the radius calculation.
        #expect((1.7...1.9).contains(joined.radiusKm))
        let separate = try #require(clusters.first { $0.members.count == 1 })
        #expect(separate.members.map(\.id) == [isolated.id])
    }

    @Test("disc radius is the member p90 floored at 1 km")
    func discRadiusFloor() {
        var stays: [HomeOrbit.StayObservation] = []
        var id = 0
        for day in visitDays.suffix(3) {
            stays.append(obs(id, at(day, hour: 11), hours: 5,
                             lat: Self.village.lat, lon: Self.village.lon)); id += 1
        }
        let clusters = HomeOrbit.clusters(from: stays)
        #expect(clusters.count == 1)
        #expect(clusters[0].radiusKm == HomeOrbit.discFloorRadiusKm)
    }

    // MARK: - Validity edges

    @Test("a pattern's disc never claims time from before the pattern began (no backward overreach)")
    func noBackwardOverreach() {
        // Start working outside town on Mar 1: returns Mar 1, 2, 3. The
        // ORIGINAL containing-window rule made this valid from the previous
        // April — so a genuine trip to the same spot eleven months earlier
        // would be claimed as home and dissolved. Day 0 of an expansion is
        // the pattern's own first return.
        let returns = [utc(2025, 3, 1, 17), utc(2025, 3, 2, 17), utc(2025, 3, 3, 17)]
        let intervals = HomeOrbit.validityIntervals(returnTimes: returns)
        #expect(!intervals.isEmpty)
        #expect(!intervals.contains { $0.start <= utc(2024, 9, 1) && utc(2024, 9, 1) <= $0.end },
                "validity reached back before the pattern existed")
        #expect(!intervals.contains { $0.contains(utc(2025, 2, 20)) },
                "even nine days pre-pattern must not be claimed")
        // The pattern's own first day IS covered (the 12 h clause-b pad).
        #expect(intervals.contains { $0.contains(utc(2025, 3, 1, 9)) })
    }

    @Test("forgetting runs from the LAST return, so a sparse-but-alive routine never expires mid-pattern")
    func forgettingRunsFromLastReturn() {
        // Three returns spanning 11 months. The original rule expired this
        // disc 12 months after the FIRST return — mid-pattern.
        let returns = [utc(2024, 1, 15, 17), utc(2024, 6, 15, 17), utc(2024, 12, 15, 17)]
        let intervals = HomeOrbit.validityIntervals(returnTimes: returns)
        #expect(intervals.contains { $0.contains(utc(2025, 11, 1)) },
                "valid until 12 months after the LAST return")
        #expect(!intervals.contains { $0.contains(utc(2026, 1, 15)) },
                "and forgotten after that")
    }

    // MARK: - Membership invariants

    @Test("D* is the seed's scale and does not move when discs join")
    func scaleIsSeedOnly() {
        let seed = Self.squareSeed()
        let disc = HomeOrbit.OrbitDisc(
            centerLatitude: Self.village.lat, centerLongitude: Self.village.lon,
            radiusKm: 1, validity: [DateInterval(start: .distantPast, end: .distantFuture)],
            returnTimes: [])
        let bare = HomeMembership(seed: seed)
        let grown = HomeMembership(seed: seed, orbitDiscs: [disc])
        #expect(bare.scaleKm == grown.scaleKm)
        #expect(bare.scaleKm == seed.areaEquivalentRadiusKm)
    }

    @Test("membership: a valid disc covers and shortens D; an expired one does neither")
    func membershipRespectsValidity() {
        let seed = Self.squareSeed()
        let window = DateInterval(start: utc(2024, 5, 15), end: utc(2025, 5, 14))
        let disc = HomeOrbit.OrbitDisc(
            centerLatitude: Self.village.lat, centerLongitude: Self.village.lon,
            radiusKm: 1, validity: [window], returnTimes: [])
        let m = HomeMembership(seed: seed, orbitDiscs: [disc])
        let insideWindow = utc(2024, 10, 13), outsideWindow = utc(2026, 10, 13)
        #expect(m.contains(latitude: Self.village.lat, longitude: Self.village.lon, at: insideWindow))
        #expect(!m.contains(latitude: Self.village.lat, longitude: Self.village.lon, at: outsideWindow))
        let dValid = m.distanceKm(toLatitude: Self.island.lat, longitude: Self.island.lon, at: insideWindow)
        let dExpired = m.distanceKm(toLatitude: Self.island.lat, longitude: Self.island.lon, at: outsideWindow)
        #expect(dValid < dExpired, "a valid disc must shorten D toward places beyond it")
        #expect(dExpired == seed.distanceKm(toLatitude: Self.island.lat, longitude: Self.island.lon))
    }

    @Test("an exclude suppresses a learned disc but can never carve the seed")
    func excludeBeatsOrbitNeverSeed() {
        let seed = Self.squareSeed()
        let disc = HomeOrbit.OrbitDisc(
            centerLatitude: Self.village.lat, centerLongitude: Self.village.lon,
            radiusKm: 1, validity: [DateInterval(start: .distantPast, end: .distantFuture)],
            returnTimes: [])
        let m = HomeMembership(
            seed: seed, orbitDiscs: [disc],
            excludeDiscs: [(Self.village.lat, Self.village.lon, 2.0),
                           (Self.homeLat, Self.homeLon, 5.0)])   // tries to carve the seed
        let now = utc(2024, 10, 13)
        #expect(!m.contains(latitude: Self.village.lat, longitude: Self.village.lon, at: now))
        // The seed exclusion attempt is a no-op: downtown is still home.
        #expect(m.contains(latitude: Self.homeLat, longitude: Self.homeLon, at: now))
    }

    @Test("derivation drops clusters whose centre falls in an exclude")
    func derivationHonoursExcludes() {
        let seed = Self.squareSeed()
        var stays: [HomeOrbit.StayObservation] = []
        var id = 0
        for day in visitDays.suffix(3) {
            stays.append(home(id, at(day, hour: 0), hours: 8)); id += 1
            stays.append(obs(id, at(day, hour: 11), hours: 5,
                             lat: Self.village.lat, lon: Self.village.lon)); id += 1
            stays.append(home(id, at(day, hour: 18), hours: 12)); id += 1
        }
        let audits = HomeOrbit.deriveDiscs(
            observations: stays, seed: seed,
            excludes: [(Self.village.lat, Self.village.lon, 2.0)])
        #expect(audits.compactMap(\.disc).isEmpty)
    }


    // MARK: - Derivation equivalence (hoisted per-run clauses)

    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// An independent per-cluster scan over the raw observations: it forms
    /// its own runs and brackets instead of reading the production
    /// excursions' closure fields. Valid for histories without overlapping
    /// observations, which is what the generator below produces.
    private static func referenceReturns(
        latitude: Double, longitude: Double, radiusKm: Double,
        observations: [HomeOrbit.StayObservation], seed: HomeShape
    ) -> [Date] {
        let ordered = observations.sorted {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }
        func isHome(_ stay: HomeOrbit.StayObservation) -> Bool {
            seed.contains(latitude: stay.latitude, longitude: stay.longitude)
        }
        let unknown = PresenceEvidence.unknownGapSeconds
        var times: [Date] = []
        var index = 0
        while index < ordered.count {
            guard !isHome(ordered[index]) else { index += 1; continue }
            var last = index
            var reach = ordered[index].end
            while last + 1 < ordered.count, !isHome(ordered[last + 1]),
                  ordered[last + 1].start.timeIntervalSince(reach) <= unknown {
                last += 1
                reach = max(reach, ordered[last].end)
            }
            let run = Array(ordered[index...last])
            let before: HomeOrbit.StayObservation? = index > 0 ? ordered[index - 1] : nil
            let after: HomeOrbit.StayObservation? =
                last + 1 < ordered.count ? ordered[last + 1] : nil
            index = last + 1
            let first = run[0]
            guard let before, isHome(before), before.isLive,
                  before.end <= first.start,
                  first.start.timeIntervalSince(before.end) <= unknown,
                  let after, isHome(after), after.isLive,
                  reach <= after.start,
                  after.start.timeIntervalSince(reach) <= unknown,
                  after.start.timeIntervalSince(first.start) <= HomeOrbit.returnWindowSeconds,
                  run.contains(where: { !$0.isTransitNode })
            else { continue }
            let members = run.filter {
                $0.isLive && !$0.isTransitNode &&
                HomeOrbit.greatCircleKm(latitude, longitude, $0.latitude, $0.longitude)
                    <= radiusKm
            }
            guard !members.isEmpty else { continue }
            let dwell = members.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
            guard dwell >= HomeOrbit.dwellFloorSeconds else { continue }
            times.append(after.start)
        }
        return times.sorted()
    }

    @Test("derived return times match the per-cluster reference scan on random fallback-disc histories",
          arguments: [(38.0126, 23.7128), (70.0, 25.0), (-16.5, 179.99), (65.0, -179.99)])
    func deriveDiscsMatchesReferenceScan(home: (Double, Double)) {
        var rng = SplitMix(state: UInt64(bitPattern: Int64(home.0 * 1000 + home.1)))
        let seed = HomeShape.fallbackDisc(latitude: home.0, longitude: home.1)
        // A handful of away places, some pairs close enough to share reach.
        let places: [(Double, Double)] = (0..<8).map { _ in
            (home.0 + Double.random(in: -0.4...0.4, using: &rng),
             home.1 + Double.random(in: -0.4...0.4, using: &rng))
        }
        var stays: [HomeOrbit.StayObservation] = []
        var id = 0
        var t = utc(2023, 5, 15, 0)
        for _ in 0..<160 {
            // Occasionally no witnessed departure or return, an imported home
            // bracket, or a week-long hole in the record.
            if Int.random(in: 0..<8, using: &rng) != 0 {
                stays.append(obs(id, t, hours: 8, lat: home.0, lon: home.1,
                                 live: Int.random(in: 0..<10, using: &rng) != 0)); id += 1
                t = t.addingTimeInterval(8 * 3600)
            }
            for _ in 0..<Int.random(in: 1...4, using: &rng) {
                let place = places[Int.random(in: 0..<places.count, using: &rng)]
                // Jitter up to ~1.5 km so members straddle the disc radius.
                let hours = [0.05, 0.4, 1.0, 3.0, 14.0][Int.random(in: 0..<5, using: &rng)]
                stays.append(obs(id, t, hours: hours,
                                 lat: place.0 + Double.random(in: -0.013...0.013, using: &rng),
                                 lon: place.1 + Double.random(in: -0.013...0.013, using: &rng),
                                 transit: Int.random(in: 0..<8, using: &rng) == 0,
                                 live: Int.random(in: 0..<6, using: &rng) != 0)); id += 1
                t = t.addingTimeInterval(hours * 3600)
            }
            if Int.random(in: 0..<8, using: &rng) != 0 {
                stays.append(obs(id, t, hours: 10, lat: home.0, lon: home.1)); id += 1
                t = t.addingTimeInterval(10 * 3600)
            }
            let hole = Int.random(in: 0..<12, using: &rng) == 0
            t = t.addingTimeInterval(
                (hole ? 9 * 24 : Double.random(in: 1...70, using: &rng)) * 3600)
        }

        let audits = HomeOrbit.deriveDiscs(observations: stays, seed: seed)
        #expect(!audits.isEmpty)
        #expect(audits.contains { !$0.qualifyingReturnTimes.isEmpty })
        for audit in audits {
            let expected = Self.referenceReturns(
                latitude: audit.centerLatitude, longitude: audit.centerLongitude,
                radiusKm: audit.radiusKm, observations: stays, seed: seed)
            #expect(audit.qualifyingReturnTimes == expected)
            #expect((audit.disc != nil)
                    == !HomeOrbit.validityIntervals(returnTimes: expected).isEmpty)
        }
    }

}
