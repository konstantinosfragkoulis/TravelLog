//
//  TripConfidenceTests.swift
//  TravelLogTests
//
//  Pins the score and excursion formation against ten independently specified
//  score cases (trip lists produced by a fixed-radius rule are a function of
//  that radius and cannot validate a distance rule) and against the failure
//  modes each rule was written to prevent.
//

import Foundation
import CoreLocation
import Testing
@testable import TravelLog

struct TripConfidenceTests {

    private static let home = (lat: 38.0, lon: 23.8)

    private static func athens() async -> HomeShape {
        await HomeShapeResolver.resolve(latitude: home.lat, longitude: home.lon)
    }

    private static func stay(
        _ startHours: Double, _ durationHours: Double,
        _ lat: Double, _ lon: Double, transit: Bool = false
    ) -> TripConfidence.StayInput {
        let base = Date(timeIntervalSince1970: 1_670_969_600)
        return .init(id: UUID(),
                     start: base.addingTimeInterval(startHours * 3600),
                     end: base.addingTimeInterval((startHours + durationHours) * 3600),
                     latitude: lat, longitude: lon, isTransitNode: transit)
    }

    // MARK: - Accretion crossing (closed form)

    @Test("accretionClearsAt is the exact instant the duration term lifts the score to θ")
    func accretionCrossingMatchesTheScore() async throws {
        let shape = await Self.athens()
        // Sounio for 1 h: the 3 h case sits just above θ, so 1 h is
        // sub-θ and the crossing lies a couple of hours out.
        let input = Self.stay(0, 1, 37.6500, 24.0270)
        let excursions = TripConfidence.excursions(from: [input], shapes: [shape])
        let excursion = try #require(excursions.first)
        #expect(!excursion.isTrip)
        let clearsAt = try #require(excursion.accretionClearsAt)
        #expect(clearsAt > excursion.end)

        // Re-score with the stay extended to the reported instant (minus the
        // safety margin) and just before it.
        func score(endingAt end: Date) -> Double {
            let extended = TripConfidence.StayInput(
                id: input.id, start: input.start, end: end,
                latitude: input.latitude, longitude: input.longitude,
                isTransitNode: false)
            return TripConfidence.excursions(from: [extended], shapes: [shape]).first?.score ?? 0
        }
        let exact = clearsAt.addingTimeInterval(-TripConfidence.accretionMarginSeconds)
        #expect(score(endingAt: exact) >= TripConfidence.threshold - 1e-9)
        #expect(score(endingAt: exact.addingTimeInterval(-3600)) < TripConfidence.threshold)
        #expect(score(endingAt: clearsAt) >= TripConfidence.threshold)
    }

    @Test("accretionClearsAt is nil once the excursion clears, and for a zero distance term")
    func accretionCrossingAbsentWhenIrrelevant() async {
        let shape = await Self.athens()
        let cleared = TripConfidence.excursions(
            from: [Self.stay(0, 72, 37.6500, 24.0270)], shapes: [shape]).first
        #expect(cleared?.isTrip == true)
        #expect(cleared?.accretionClearsAt == nil)

        let zero = TripConfidence.Excursion(
            stays: [Self.stay(0, 2, 37.6500, 24.0270)], distanceKm: 0,
            durationHours: 2, score: 0)
        #expect(zero.accretionClearsAt == nil)
    }

    // MARK: - The derived threshold

    @Test("θ is exactly the score at the model's own two scales")
    func thresholdIsDerived() {
        // score(D = D*, T = T*) = log2(2) * (1 + log2(2)) = 1 * 2
        let atUnitPoint = TripConfidence.score(
            distanceKm: 11.45, durationHours: 24, scaleKm: 11.45)
        #expect(abs(atUnitPoint - 2.0) < 1e-12)
        #expect(TripConfidence.threshold == 2.0)
    }

    @Test("D gates T — no duration promotes a stay inside the shape")
    func distanceGatesDuration() {
        for hours in [1.0, 24.0, 96.0, 8760.0] {
            #expect(TripConfidence.score(
                distanceKm: 0, durationHours: hours, scaleKm: 11.45) == 0)
        }
    }

    @Test("the score is monotone in both arguments")
    func monotonicity() {
        var previous = -1.0
        for d in stride(from: 1.0, through: 200, by: 7) {
            let s = TripConfidence.score(distanceKm: d, durationHours: 12, scaleKm: 11.45)
            #expect(s > previous); previous = s
        }
        previous = -1.0
        for t in stride(from: 1.0, through: 300, by: 11) {
            let s = TripConfidence.score(distanceKm: 30, durationHours: t, scaleKm: 11.45)
            #expect(s > previous); previous = s
        }
    }

    @Test("negative and zero inputs are absorbed, never NaN")
    func degenerateInputs() {
        #expect(TripConfidence.score(distanceKm: -5, durationHours: 10, scaleKm: 11).isZero)
        #expect(TripConfidence.score(distanceKm: 10, durationHours: -5, scaleKm: 11) > 0)
        #expect(TripConfidence.score(distanceKm: 10, durationHours: 10, scaleKm: 0).isZero)
        #expect(TripConfidence.score(distanceKm: 10, durationHours: 10, scaleKm: 11).isFinite)
    }

    // MARK: - The ten specified score cases, against the real shipped shape

    @Test("every specified score case is reproduced at θ = 2.0")
    func namedJudgements() async {
        let shape = await Self.athens()
        // (place, lat, lon, hours, isTrip?): nil marks the deliberately near-threshold case.
        let cases: [(String, Double, Double, Double, Bool?)] = [
            ("Agios Dimitrios",   37.9343, 23.7341,  12, false),
            ("Néa Pentéli evening", 38.0606, 23.8593,   3, false),
            ("Peristéri day out", 38.0212, 23.6894,   9, false),
            ("Diónysos 4 h",      38.1003, 23.8835,   4, false),
            ("Kavos Club night",  37.7944, 23.7422,   5, false),
            ("Sounio 3 h",        37.6500, 24.0270,   3, nil),
            ("Livadeiá day trip", 38.4366, 22.8758, 4.4, true),
            ("Aegina 1 day",      37.7470, 23.4270,  24, true),
            ("Sounio 4 days",     37.6500, 24.0270,  96, true),
            ("Syros a week",      37.4465, 24.9419, 168, true),
        ]
        for (name, lat, lon, hours, expected) in cases {
            let s = TripConfidence.score(latitude: lat, longitude: lon,
                                         durationHours: hours, shapes: [shape])
            guard let expected else {
                // Contested: must sit just ABOVE the line, not on it. Pinning
                // the boundary onto the ambiguous case is what 2.12 got wrong.
                #expect(s > TripConfidence.threshold && s < 2.4, "\(name) scored \(s)")
                continue
            }
            #expect((s >= TripConfidence.threshold) == expected,
                    "\(name) scored \(s), expected isTrip=\(expected)")
        }
    }

    // MARK: - Multi-home: D* stays per-home

    @Test("a large second home abroad cannot delete near trips at the first")
    func perHomeScaleIsNotUnioned() async {
        let athens = await Self.athens()
        let istanbul = await HomeShapeResolver.resolve(latitude: 41.0129, longitude: 29.0591)
        // Istanbul is 1,269 km²; a union would inflate D* to about 24 km and
        // sink the nearby day trip below θ.
        let alone = TripConfidence.score(latitude: 38.4640, longitude: 23.6020,
                                         durationHours: 4.4, shapes: [athens])
        let withSecond = TripConfidence.score(latitude: 38.4640, longitude: 23.6020,
                                              durationHours: 4.4, shapes: [athens, istanbul])
        #expect(alone >= TripConfidence.threshold)
        #expect(withSecond == alone, "second home changed a far-away score")
    }

    @Test("arriving at either home reads as home")
    func eitherHomeIsHome() async {
        let athens = await Self.athens()
        let istanbul = await HomeShapeResolver.resolve(latitude: 41.0129, longitude: 29.0591)
        let inIstanbul = TripConfidence.score(latitude: 41.0129, longitude: 29.0591,
                                              durationHours: 96, shapes: [athens, istanbul])
        #expect(inIstanbul == 0)
    }

    @Test("no declared home means no trips, not all trips")
    func noHomes() {
        #expect(TripConfidence.score(latitude: 0, longitude: 0,
                                     durationHours: 999, shapes: []) == 0)
        #expect(TripConfidence.excursions(from: [Self.stay(0, 5, 0, 0)], shapes: []).isEmpty)
    }

    // MARK: - Excursion formation

    @Test("an excursion is bracketed by presence inside the shape")
    func bracketing() async throws {
        let shape = await Self.athens()
        let run = [
            Self.stay(0, 10, Self.home.lat, Self.home.lon),      // home
            Self.stay(20, 6, 38.4366, 22.8758),                  // Livadeiá
            Self.stay(30, 10, Self.home.lat, Self.home.lon),     // home again
        ]
        let excursions = TripConfidence.excursions(from: run, shapes: [shape])
        let only = try #require(excursions.first)
        #expect(excursions.count == 1)
        #expect(only.stays.count == 1)
        #expect(only.isTrip)
    }

    private static func bracket(
        _ stay: TripConfidence.StayInput
    ) -> TripConfidence.HomeBracket {
        .init(stayID: stay.id, start: stay.start, end: stay.end)
    }

    @Test("excursions record the home stays around them without changing their stays or score")
    func homeBracketsAreRecorded() throws {
        let shape = HomeShape.fallbackDisc(latitude: Self.home.lat, longitude: Self.home.lon)
        let before = Self.stay(0, 10, Self.home.lat, Self.home.lon)
        let away = Self.stay(20, 6, 38.4366, 22.8758)
        let after = Self.stay(30, 10, Self.home.lat, Self.home.lon)

        let closed = try #require(TripConfidence.excursions(
            from: [before, away, after], shapes: [shape]).first)
        #expect(closed.departure == Self.bracket(before))
        #expect(closed.homeReturn == Self.bracket(after))

        // End of input: same run, same score, no witnessed return.
        let open = TripConfidence.excursions(from: [before, away], shapes: [shape])
        #expect(open.count == 1)
        let only = try #require(open.first)
        #expect(only.departure == Self.bracket(before))
        #expect(only.homeReturn == nil)
        #expect(only.stays == closed.stays)
        #expect(only.score == closed.score)
        #expect(only.distanceKm == closed.distanceKm)
        #expect(only.durationHours == closed.durationHours)

        // No home stay before the run: no departure.
        let unled = try #require(TripConfidence.excursions(
            from: [away, after], shapes: [shape]).first)
        #expect(unled.departure == nil)
        #expect(unled.homeReturn == Self.bracket(after))
        #expect(unled.score == closed.score)
    }

    @Test("an unknown gap closes a run without a return, and the next run has no departure")
    func unknownGapsWitnessNothing() {
        let shape = HomeShape.fallbackDisc(latitude: Self.home.lat, longitude: Self.home.lon)
        let week = PresenceEvidence.unknownGapSeconds / 3600
        let before = Self.stay(0, 10, Self.home.lat, Self.home.lon)
        let first = Self.stay(12, 2, 38.4366, 22.8758)
        let second = Self.stay(14 + week + 1, 2, 38.4366, 22.8758)
        let after = Self.stay(17 + week + 1, 10, Self.home.lat, Self.home.lon)
        let excursions = TripConfidence.excursions(
            from: [before, first, second, after], shapes: [shape])
        #expect(excursions.count == 2)
        #expect(excursions.first?.departure == Self.bracket(before))
        #expect(excursions.first?.homeReturn == nil)
        #expect(excursions.last?.departure == nil)
        #expect(excursions.last?.homeReturn == Self.bracket(after))

        // A leading unknown gap: the home stay is too long ago to witness a departure.
        let late = Self.stay(10 + week + 1, 2, 38.4366, 22.8758)
        let lateAfter = Self.stay(13 + week + 1, 10, Self.home.lat, Self.home.lon)
        let leading = TripConfidence.excursions(
            from: [before, late, lateAfter], shapes: [shape])
        #expect(leading.count == 1)
        #expect(leading.first?.departure == nil)
        #expect(leading.first?.homeReturn == Self.bracket(lateAfter))
    }

    @Test("an unknown closure forgets earlier home evidence, even a home stay that ended later")
    func unknownClosureClearsDeparture() {
        let shape = HomeShape.fallbackDisc(latitude: Self.home.lat, longitude: Self.home.lon)
        // A long home stay overlaps a short outing; the outing's run then
        // closes on an unknown gap. Without forgetting, the long stay (which
        // ended 10 h before the next run) would certify its departure.
        let longHome = Self.stay(0, 200, Self.home.lat, Self.home.lon)
        let outing = Self.stay(1, 1, 38.4366, 22.8758)
        let next = Self.stay(210, 2, 38.4366, 22.8758)
        let after = Self.stay(214, 10, Self.home.lat, Self.home.lon)
        let excursions = TripConfidence.excursions(
            from: [longHome, outing, next, after], shapes: [shape])
        #expect(excursions.count == 2)
        #expect(excursions.first?.departure == Self.bracket(longHome))
        #expect(excursions.first?.homeReturn == nil)
        #expect(excursions.last?.stays.map(\.id) == [next.id])
        #expect(excursions.last?.departure == nil)
        #expect(excursions.last?.homeReturn == Self.bracket(after))
    }

    @Test("an unknown interval terminates a run instead of welding separate excursions")
    func unknownIntervalSplits() async {
        let shape = await Self.athens()
        let run = [
            Self.stay(0, 12, 37.4465, 24.9419),                  // Syros
            Self.stay(16.6 * 24, 12, 37.5315, 25.1554),          // Tinos, 16.6 d later
            Self.stay(16.6 * 24 + 40.1 * 24, 12, 39.9242, 21.8103), // Deskáti, 40.1 d
        ]
        let excursions = TripConfidence.excursions(from: run, shapes: [shape])
        #expect(excursions.count == 3, "got \(excursions.count) — the weld is back")
    }

    // MARK: - Transit-node neutrality

    @Test("dropping someone at the airport and driving home is not a trip")
    func airportRoundTripIsNotATrip() async {
        let shape = await Self.athens()
        let run = [
            Self.stay(0, 1, Self.home.lat, Self.home.lon),
            Self.stay(2, 1, 37.9429, 23.9315, transit: true),   // ATH
            Self.stay(4, 1, Self.home.lat, Self.home.lon),
        ]
        // It may FORM a run (neutrality demotes, it never erases) but the score
        // must reject it: ATH is only 6.9 km beyond the shape.
        let excursions = TripConfidence.excursions(from: run, shapes: [shape])
        #expect(excursions.allSatisfy { !$0.isTrip })
        // Even a full day parked at the airport stays ordinary.
        let longRun = [
            Self.stay(0, 1, Self.home.lat, Self.home.lon),
            Self.stay(2, 24, 37.9429, 23.9315, transit: true),
            Self.stay(30, 1, Self.home.lat, Self.home.lon),
        ]
        #expect(TripConfidence.excursions(from: longRun, shapes: [shape])
            .allSatisfy { !$0.isTrip })
    }

    @Test("flying out starts the trip AT the airport")
    func airportAttachesToTheFront() async throws {
        let shape = await Self.athens()
        let run = [
            Self.stay(0, 1, Self.home.lat, Self.home.lon),
            Self.stay(2, 2, 37.9429, 23.9315, transit: true),   // ATH
            Self.stay(6, 96, 37.4465, 24.9419),                 // Syros
            Self.stay(110, 2, Self.home.lat, Self.home.lon),
        ]
        let excursions = TripConfidence.excursions(from: run, shapes: [shape])
        let only = try #require(excursions.first)
        #expect(excursions.count == 1)
        #expect(only.stays.count == 2, "the airport should be absorbed")
        #expect(only.stays.first?.isTransitNode == true)
        #expect(only.isTrip)
    }

    @Test("a neutral stay never sets how far a trip reached")
    func airportDoesNotSetDistance() async throws {
        let shape = await Self.athens()
        // A far-flung airport with a NEAR real destination must not inherit the
        // airport's distance.
        let run = [
            Self.stay(0, 1, Self.home.lat, Self.home.lon),
            Self.stay(2, 1, 37.4465, 24.9419, transit: true),    // 111 km, neutral
            Self.stay(4, 4, 38.4366, 22.8758),                   // Livadeiá, 78.3 km
            Self.stay(10, 1, Self.home.lat, Self.home.lon),
        ]
        let excursions = TripConfidence.excursions(from: run, shapes: [shape])
        let only = try #require(excursions.first)
        #expect(excursions.count == 1)
        #expect(abs(only.distanceKm - 78.3) < 1.0,
                "D = \(only.distanceKm), the neutral stay leaked in")
    }

    @Test("neutrality can never DELETE a trip — the all-airport run")
    func allNeutralRunStillScores() async throws {
        let shape = await Self.athens()
        // Two photo-import stays close enough to an island's airport to be
        // flagged neutral. Dropping runs with no non-neutral stay would lose
        // a legitimate excursion like this one outright.
        let run = [
            Self.stay(0, 1, Self.home.lat, Self.home.lon),
            Self.stay(2, 12, 38.1201, 20.5005, transit: true), // EFL
            Self.stay(26, 12, 38.1201, 20.5005, transit: true),
        ]
        let excursions = TripConfidence.excursions(from: run, shapes: [shape])
        let only = try #require(excursions.first)
        #expect(excursions.count == 1)
        #expect(only.isTrip, "an all-neutral excursion was deleted by neutrality")
        #expect(only.distanceKm > 100)
    }

    @Test("results are order-independent and deterministic")
    func deterministic() async {
        let shape = await Self.athens()
        let run = [
            Self.stay(0, 1, Self.home.lat, Self.home.lon),
            Self.stay(4, 6, 38.4366, 22.8758),
            Self.stay(12, 1, Self.home.lat, Self.home.lon),
            Self.stay(40, 30, 37.4465, 24.9419),
            Self.stay(80, 1, Self.home.lat, Self.home.lon),
        ]
        let forward = TripConfidence.excursions(from: run, shapes: [shape])
        let shuffled = TripConfidence.excursions(from: run.reversed(), shapes: [shape])
        #expect(forward == shuffled)
        #expect(forward.count == 2)
    }

    // MARK: - Dated membership (a temporary home after its end)

    private static let athensCentre = (lat: 38.0, lon: 23.8)
    private static let brusselsCentre = (lat: 50.85, lon: 4.35)
    /// About 1.1 km north of the Brussels square's edge.
    private static let brusselsSuburb = (lat: 50.91, lon: 4.35)

    /// A 10 km square urban centre around `centre`: D* ≈ 5.64 km.
    private static func square(id: Int64, around centre: (lat: Double, lon: Double)) -> HomeShape {
        HomeShape.urbanCentre(
            id: id, name: "City \(id)", areaKm2: 100,
            rings: [[[centre.lon - 0.05, centre.lat - 0.05, centre.lon + 0.05, centre.lat - 0.05,
                      centre.lon + 0.05, centre.lat + 0.05, centre.lon - 0.05, centre.lat + 0.05]]],
            centreLatitude: centre.lat, centreLongitude: centre.lon)
    }

    private static func day(_ offset: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: (offset - 336) * 86_400)
    }

    private static func visit(
        _ place: (lat: Double, lon: Double), fromDay: Double, hours: Double, transit: Bool = false
    ) -> TripConfidence.StayInput {
        .init(id: UUID(), start: day(fromDay), end: day(fromDay).addingTimeInterval(hours * 3600),
              latitude: place.lat, longitude: place.lon, isTransitNode: transit)
    }

    private static var athensArea: HomeMembership { HomeMembership(seed: square(id: 1, around: athensCentre)) }
    private static var brusselsArea: HomeMembership { HomeMembership(seed: square(id: 2, around: brusselsCentre)) }

    @Test("a stay at the base after a temporary home's end does not close the run before it: the run holds both stays and is scored against the real home alone")
    func datedMembershipDoesNotCloseARunOutsideItsEra() throws {
        let semester = Self.brusselsArea.clamped(toEra: DateInterval(start: Self.day(1), end: Self.day(10)))
        let errand = Self.visit(Self.brusselsSuburb, fromDay: 9.8, hours: 3.6)
        let base = Self.visit(Self.brusselsCentre, fromDay: 10.1, hours: 3.7 * 24)

        let dated = TripConfidence.excursions(from: [errand, base], memberships: [Self.athensArea, semester])
        let only = try #require(dated.first)
        #expect(dated.count == 1)
        #expect(only.stays.map(\.id) == [errand.id, base.id])
        #expect(only.isTrip)
        #expect(only.hasScoringMembership)
        #expect(dated == TripConfidence.excursions(from: [errand, base], memberships: [Self.athensArea]))
    }

    @Test("inside its dates a temporary home still closes a run and scores it, exactly as an undated home does")
    func datedMembershipStillScoresARunInsideItsEra() throws {
        let semester = Self.brusselsArea.clamped(toEra: DateInterval(start: Self.day(1), end: Self.day(10)))
        let errand = Self.visit(Self.brusselsSuburb, fromDay: 9.8, hours: 3.6)
        let base = Self.visit(Self.brusselsCentre, fromDay: 9.96, hours: 0.5)

        let dated = TripConfidence.excursions(from: [errand, base], memberships: [Self.athensArea, semester])
        let only = try #require(dated.first)
        #expect(dated.count == 1)
        #expect(only.stays.map(\.id) == [errand.id])
        #expect(only.homeReturn?.stayID == base.id)
        #expect(!only.isTrip)
        #expect(dated == TripConfidence.excursions(
            from: [errand, base], memberships: [Self.athensArea, Self.brusselsArea]))
    }

    @Test("a stay at the base before a temporary home's start joins the errand after it, and the run is scored against the real home alone")
    func datedMembershipMirrorAtTheStart() throws {
        let semester = Self.brusselsArea.clamped(toEra: DateInterval(start: Self.day(10), end: Self.day(20)))
        let base = Self.visit(Self.brusselsCentre, fromDay: 9.2, hours: 0.7 * 24)
        let errand = Self.visit(Self.brusselsSuburb, fromDay: 10.3, hours: 3.6)

        let dated = TripConfidence.excursions(from: [base, errand], memberships: [Self.athensArea, semester])
        let only = try #require(dated.first)
        #expect(dated.count == 1)
        #expect(only.stays.map(\.id) == [base.id, errand.id])
        #expect(only.isTrip)
        #expect(dated == TripConfidence.excursions(from: [base, errand], memberships: [Self.athensArea]))
    }

    @Test("a transit stop at the base after the end takes the temporary home out of scoring the run, although it sets no distance")
    func outOfEraTransitTakesTheBaseOutOfScoring() throws {
        let semester = Self.brusselsArea.clamped(toEra: DateInterval(start: Self.day(1), end: Self.day(10)))
        let errand = Self.visit(Self.brusselsSuburb, fromDay: 9.8, hours: 3.6)
        let after = Self.visit(Self.brusselsCentre, fromDay: 10.1, hours: 1, transit: true)

        let dated = TripConfidence.excursions(from: [errand, after], memberships: [Self.athensArea, semester])
        #expect(dated.map { $0.stays.map(\.id) } == [[errand.id, after.id]])
        #expect(dated.first?.isTrip == true)
        #expect(dated == TripConfidence.excursions(from: [errand, after], memberships: [Self.athensArea]))

        // Control: the same stop inside the dates is presence at the base and closes the errand's run.
        let inside = Self.visit(Self.brusselsCentre, fromDay: 9.97, hours: 1, transit: true)
        let closed = TripConfidence.excursions(from: [errand, inside], memberships: [Self.athensArea, semester])
        #expect(closed.map { $0.stays.map(\.id) } == [[errand.id]])
        #expect(closed.first?.isTrip == false)
    }

    @Test("a run that no membership existed throughout is unscored: score and distance are placeholders, not a reading near home")
    func aRunNoMembershipSpansIsUnscored() throws {
        let semester = Self.brusselsArea.clamped(toEra: DateInterval(start: Self.day(1), end: Self.day(10)))
        let errand = Self.visit(Self.brusselsSuburb, fromDay: 9.8, hours: 3.6)
        let base = Self.visit(Self.brusselsCentre, fromDay: 10.1, hours: 3.7 * 24)

        let excursions = TripConfidence.excursions(from: [errand, base], memberships: [semester])
        let only = try #require(excursions.first)
        #expect(excursions.count == 1)
        #expect(!only.hasScoringMembership)
        #expect(only.score == 0)
        #expect(only.distanceKm == 0)
        #expect(!only.isTrip)
        #expect(only.accretionClearsAt == nil)
    }

    @Test("a dated membership exists from its start through its end, both inclusive, and contains nothing a second outside; an undated one always exists")
    func membershipEraIsInclusiveAtBothEnds() {
        let start = Self.day(1)
        let end = Self.day(10)
        let semester = Self.brusselsArea.clamped(toEra: DateInterval(start: start, end: end))
        func inside(_ date: Date) -> Bool {
            semester.contains(latitude: Self.brusselsCentre.lat, longitude: Self.brusselsCentre.lon, at: date)
        }
        #expect(!inside(start.addingTimeInterval(-1)))
        #expect(inside(start))
        #expect(inside(Self.day(5)))
        #expect(inside(end))
        #expect(!inside(end.addingTimeInterval(1)))
        #expect(semester.isValid(at: end))
        #expect(!semester.isValid(at: end.addingTimeInterval(1)))
        #expect(semester.era == DateInterval(start: start, end: end))
        #expect(semester != Self.brusselsArea)

        #expect(Self.brusselsArea.era == nil)
        #expect(Self.brusselsArea.isValid(at: .distantPast))
        #expect(Self.brusselsArea.contains(
            latitude: Self.brusselsCentre.lat, longitude: Self.brusselsCentre.lon, at: .distantFuture))
    }

    // MARK: - Differential proof: undated memberships score as before

    /// `TripConfidence.excursions(from:memberships:)` as it stood before dated
    /// memberships, copied verbatim (type names qualified).
    private static func excursionsBeforeDatedMembership(
        from stays: [TripConfidence.StayInput], memberships: [HomeMembership]
    ) -> [TripConfidence.Excursion] {
        guard !memberships.isEmpty else { return [] }
        let ordered = stays.sorted {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }

        func isInsideAnyShape(_ stay: TripConfidence.StayInput) -> Bool {
            memberships.contains {
                $0.contains(latitude: stay.latitude, longitude: stay.longitude,
                            at: stay.start)
            }
        }

        var runs: [(stays: [TripConfidence.StayInput], departure: TripConfidence.HomeBracket?,
                    homeReturn: TripConfidence.HomeBracket?)] = []
        var current: [TripConfidence.StayInput] = []
        var reach: Date?
        var departure: TripConfidence.HomeBracket?
        var lastHome: TripConfidence.HomeBracket?

        func closeRun(homeReturn: TripConfidence.HomeBracket?) {
            if !current.isEmpty {
                runs.append((current, departure, homeReturn))
            }
            current = []
            reach = nil
            departure = nil
        }

        for stay in ordered {
            if let reach, PresenceEvidence.support(
                fromEndOf: reach, toStartOf: stay.start) == .unknown {
                closeRun(homeReturn: nil)
                lastHome = nil
            }
            if isInsideAnyShape(stay) {
                let bracket = TripConfidence.HomeBracket(stayID: stay.id, start: stay.start,
                                                         end: stay.end)
                closeRun(homeReturn: bracket)
                if lastHome.map({ stay.end >= $0.end }) ?? true {
                    lastHome = bracket
                }
            } else {
                if current.isEmpty, let lastHome, PresenceEvidence.support(
                    fromEndOf: lastHome.end, toStartOf: stay.start) == .observed {
                    departure = lastHome
                }
                current.append(stay)
                reach = max(reach ?? stay.end, stay.end)
            }
        }
        closeRun(homeReturn: nil)

        return runs.compactMap { entry in
            let run = entry.stays
            let nonNeutral = run.filter { !$0.isTransitNode }
            let anchors = nonNeutral.isEmpty ? run : nonNeutral
            guard let first = run.first, let last = run.max(by: { $0.end < $1.end }),
                  !anchors.isEmpty else { return nil }
            let durationHours = last.end.timeIntervalSince(first.start) / 3600
            var distance = 0.0
            var best = Double.greatestFiniteMagnitude
            for membership in memberships {
                var shapeDistance = 0.0
                for stay in anchors {
                    shapeDistance = max(shapeDistance, membership.distanceKm(
                        toLatitude: stay.latitude, longitude: stay.longitude,
                        at: stay.start))
                }
                let value = TripConfidence.score(distanceKm: shapeDistance,
                                                 durationHours: durationHours,
                                                 scaleKm: membership.scaleKm)
                if value < best { best = value; distance = shapeDistance }
            }
            return TripConfidence.Excursion(stays: run, distanceKm: distance,
                                            durationHours: durationHours,
                                            score: best == .greatestFiniteMagnitude ? 0 : best,
                                            departure: entry.departure,
                                            homeReturn: entry.homeReturn)
        }
    }

    @Test("with no dated membership, excursions are exactly what they were before dated memberships, over a generated grid of homes and timelines")
    func undatedMembershipsAreBitIdenticalToBefore() {
        let athens = Self.square(id: 1, around: Self.athensCentre)
        let brussels = Self.square(id: 2, around: Self.brusselsCentre)
        let fallback = HomeShape.fallbackDisc(
            latitude: Self.athensCentre.lat, longitude: Self.athensCentre.lon)
        // About 8 km east of the Athens square, where a learned disc sits for days 0 to 5.
        let outer = (lat: 38.0, lon: 23.941)
        let disc = HomeOrbit.OrbitDisc(
            centerLatitude: outer.lat, centerLongitude: outer.lon, radiusKm: 2,
            validity: [DateInterval(start: Self.day(0), end: Self.day(5))], returnTimes: [])
        let include = (latitude: 38.0, longitude: 23.8614, radiusKm: 0.5)
        let exclude = (latitude: outer.lat, longitude: outer.lon, radiusKm: 1.0)
        let sets: [[HomeMembership]] = [
            [HomeMembership(seed: athens)],
            [HomeMembership(seed: athens, orbitDiscs: [disc])],
            [HomeMembership(seed: athens, includeDiscs: [include])],
            [HomeMembership(seed: athens, orbitDiscs: [disc], excludeDiscs: [exclude])],
            [HomeMembership(seed: brussels)],
            [HomeMembership(seed: fallback, orbitDiscs: [disc])],
            [HomeMembership(seed: athens), HomeMembership(seed: brussels)],
            [HomeMembership(seed: fallback), HomeMembership(seed: brussels, includeDiscs: [include])],
        ]
        // The centre, 1 km out, 8 km out, 110 km out, the other home, and an airport.
        let places: [(lat: Double, lon: Double, transit: Bool)] = [
            (38.0, 23.8, false), (38.0, 23.8614, false), (outer.lat, outer.lon, false),
            (39.0, 23.8, false), (50.85, 4.35, false), (37.9429, 23.9315, true),
        ]
        // Start to start: two hours, most of a day, and ten days (an unknown gap).
        let spacings: [TimeInterval] = [2 * 3600, 20 * 3600, 10 * 86_400]

        func timeline(_ steps: [(place: Int, spacing: Int)]) -> [TripConfidence.StayInput] {
            var start = Self.day(0)
            return steps.enumerated().map { index, step in
                if index > 0 { start = start.addingTimeInterval(spacings[step.spacing]) }
                let place = places[step.place]
                return TripConfidence.StayInput(
                    id: UUID(), start: start, end: start.addingTimeInterval(1.5 * 3600),
                    latitude: place.lat, longitude: place.lon, isTransitNode: place.transit)
            }
        }

        var timelines: [[TripConfidence.StayInput]] = []
        // Every timeline of one to three stays.
        var partial: [[(place: Int, spacing: Int)]] = [[]]
        for _ in 1...3 {
            var longer: [[(place: Int, spacing: Int)]] = []
            for prefix in partial {
                for place in places.indices {
                    for spacing in prefix.isEmpty ? [0] : Array(spacings.indices) {
                        longer.append(prefix + [(place: place, spacing: spacing)])
                    }
                }
            }
            partial = longer
            timelines += partial.map(timeline)
        }
        // A fixed pseudo-random sample of four- and five-stay timelines.
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        for length in [4, 5] {
            for _ in 0..<300 {
                timelines.append(timeline((0..<length).map { _ in
                    (place: next(places.count), spacing: next(spacings.count))
                }))
            }
        }

        var cases = 0
        var differences = 0
        for memberships in sets {
            for stays in timelines {
                cases += 1
                let new = TripConfidence.excursions(from: stays, memberships: memberships)
                let old = Self.excursionsBeforeDatedMembership(from: stays, memberships: memberships)
                if new != old { differences += 1 }
            }
        }
        #expect(cases == sets.count * (6 + 108 + 1_944 + 600))
        #expect(differences == 0, "\(differences) of \(cases) cases differ")
    }
}
