//
//  WeatherEnrichmentPlannerTests.swift
//  TravelLogTests
//
//  Weather superlatives under partial coverage:
//   • WeatherEnrichmentPlanner — pure seasonal prior ("look in the summer",
//     hemisphere-aware, equator-flat), greedy neighbor propagation, per-trip
//     rainiest floors, deterministic ranking, and the extremes-safe stopping
//     rule.
//   • YearWrappedGenerator.weatherExtremesSafe(allStays:) — the eligibility
//     mirror (terminal marks / pre-floor / non-extreme-month home stays are
//     never measured, so never waited for).
//   • WrappedView.visibleCards — the Card-5 gate honors the persisted
//     verdict and falls back to the legacy ≥ 0.7 coverage rule on
//     pre-feature blobs (nil).
//
//  `@MainActor` only where `@Model` `Stay` rows are built (the
//  `WeatherEnricherDecisionTests` precedent); planner tests are pure values.
//

import Testing
import Foundation
@testable import TravelLog

// MARK: - Fixtures

private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
}

private func candidate(
    id: UUID = UUID(),
    lat: Double,
    lon: Double = 23.7,
    start: Date,
    durationDays: Double = 1,
    tripID: UUID? = nil,
    isTripStay: Bool = true
) -> WeatherEnrichmentPlanner.Candidate {
    WeatherEnrichmentPlanner.Candidate(
        id: id, latitude: lat, longitude: lon,
        startTime: start, endTime: start.addingTimeInterval(durationDays * 86400),
        tripID: tripID, isTripStay: isTripStay
    )
}

private func measurement(
    lat: Double,
    lon: Double = 23.7,
    start: Date,
    durationDays: Double = 1,
    tripID: UUID? = nil,
    tempC: Double
) -> WeatherEnrichmentPlanner.Measurement {
    WeatherEnrichmentPlanner.Measurement(
        latitude: lat, longitude: lon,
        startTime: start, endTime: start.addingTimeInterval(durationDays * 86400),
        tripID: tripID, avgTemperatureC: tempC
    )
}

// MARK: - Seasonal prior

struct WeatherPlannerSeasonalPriorTests {

    @Test("northern hemisphere: July is the expected hottest month, January the coldest (Athens latitude)")
    func northernHemisphereSeasonality() {
        let july = WeatherEnrichmentPlanner.expectedAvgTempC(latitude: 38, month: 7)
        let march = WeatherEnrichmentPlanner.expectedAvgTempC(latitude: 38, month: 3)
        let january = WeatherEnrichmentPlanner.expectedAvgTempC(latitude: 38, month: 1)
        #expect(july > march)
        #expect(march > january)
    }

    @Test("southern hemisphere: January beats July (Sydney latitude)")
    func southernHemisphereFlipsThePhase() {
        let january = WeatherEnrichmentPlanner.expectedAvgTempC(latitude: -33.9, month: 1)
        let july = WeatherEnrichmentPlanner.expectedAvgTempC(latitude: -33.9, month: 7)
        #expect(january > july)
    }

    @Test("equatorial latitudes are near-seasonless heat candidates year-round (Singapore vs Athens in January)")
    func equatorIsFlatAndHot() {
        let singaporeJan = WeatherEnrichmentPlanner.expectedAvgTempC(latitude: 1.3, month: 1)
        let singaporeJul = WeatherEnrichmentPlanner.expectedAvgTempC(latitude: 1.3, month: 7)
        #expect(abs(singaporeJan - singaporeJul) < 2)
        let athensJan = WeatherEnrichmentPlanner.expectedAvgTempC(latitude: 38, month: 1)
        #expect(singaporeJan > athensJan)
    }

    @Test("ceiling and floor bracket the expectation symmetrically by the prior spread")
    func ceilingAndFloorBracketTheExpectation() {
        let expected = WeatherEnrichmentPlanner.expectedAvgTempC(latitude: 38, month: 7)
        #expect(WeatherEnrichmentPlanner.seasonalCeilingC(latitude: 38, month: 7)
                == expected + WeatherEnrichmentPlanner.priorSpreadC)
        #expect(WeatherEnrichmentPlanner.seasonalFloorC(latitude: 38, month: 7)
                == expected - WeatherEnrichmentPlanner.priorSpreadC)
    }
}

// MARK: - Ranking

struct WeatherPlannerRankingTests {

    @Test("ranked values keep the source indices of identical rows and same-UUID geometry twins")
    func rankedValuesIdentifyPhysicalInputs() {
        let id = UUID()
        let first = candidate(id: id, lat: 38, lon: 23.7, start: utc(2026, 7, 10))
        let twin = candidate(id: id, lat: 38, lon: 24.7, start: utc(2026, 7, 10))
        let rows = [twin, first, first]
        let ranked = WeatherEnrichmentPlanner.rankedQueue(rows, measurements: [])
        #expect(ranked.map(\.sourceIndex) == [0, 1, 2])
        #expect(ranked.map(\.candidate) == rows)
        #expect(WeatherEnrichmentPlanner.nextCandidate(rows, measurements: [])?.sourceIndex == 0)
        #expect(WeatherEnrichmentPlanner.nextCandidate([], measurements: []) == nil)
    }

    @Test("linear selection reranks after a newly measured record promotes its same-trip neighbor")
    func nextCandidateUsesUpdatedMeasurements() {
        let promotedTrip = UUID()
        let newerTrip = UUID()
        let older = candidate(lat: 38, start: utc(2026, 7, 15), tripID: promotedTrip, isTripStay: false)
        let newer = candidate(lat: 38, start: utc(2026, 7, 16), tripID: newerTrip, isTripStay: false)
        let rows = [older, newer]
        var records = [
            measurement(lat: 80, start: utc(2026, 7, 1), tempC: 45),
            measurement(lat: 80, start: utc(2026, 1, 1), tempC: -40),
        ]
        #expect(WeatherEnrichmentPlanner.nextCandidate(rows, measurements: records)?.sourceIndex == 1)
        records.append(measurement(lat: 38, start: utc(2026, 7, 1), tripID: promotedTrip, tempC: 44))
        let selected = WeatherEnrichmentPlanner.nextCandidate(rows, measurements: records)
        #expect(selected?.sourceIndex == 0)
        #expect(selected?.score == 2)
        #expect(selected == WeatherEnrichmentPlanner.rankedQueue(rows, measurements: records).first)
    }

    /// The pre-cache algorithm, verbatim: regroup the whole series and rebuild every year.
    private func expectSameContexts(
        _ contexts: WeatherEnrichmentPlanner.YearContexts,
        as series: [WeatherEnrichmentPlanner.Measurement]
    ) {
        let regrouped = Dictionary(grouping: series) { WeatherEnrichmentPlanner.yearUTC(of: $0.startTime) }
            .mapValues { WeatherEnrichmentPlanner.YearContext(measurements: $0) }
        #expect(Set(contexts.byYear.keys) == Set(regrouped.keys))
        for (year, expected) in regrouped {
            let actual = contexts.byYear[year]
            #expect(actual?.measuredMaxC == expected.measuredMaxC)
            #expect(actual?.measuredMinC == expected.measuredMinC)
            #expect(actual?.hotFrontier == expected.hotFrontier)
            #expect(actual?.coldFrontier == expected.coldFrontier)
            #expect(actual?.tripIDsWithMeasurement == expected.tripIDsWithMeasurement)
        }
    }

    @Test("incremental year contexts select exactly what a full regroup selects after every appended measurement")
    func incrementalYearContextsMatchFullRegroup() {
        let tripA = UUID()
        let tripB = UUID()
        let twinID = UUID()
        // Ties, a same-geometry UUID twin pair, tripless rows, and three candidate years.
        var remaining = [
            candidate(lat: 38, start: utc(2025, 7, 10), tripID: tripA),
            candidate(lat: 38.2, start: utc(2025, 7, 12), tripID: tripA),
            candidate(id: twinID, lat: 10, start: utc(2025, 8, 1), tripID: tripB),
            candidate(id: twinID, lat: 10, start: utc(2025, 8, 1), tripID: tripB),
            candidate(lat: 60, start: utc(2025, 1, 15), isTripStay: false),
            candidate(lat: -33.9, start: utc(2024, 1, 20), tripID: tripB),
            candidate(lat: 45, start: utc(2026, 7, 2)),
            candidate(lat: 45, start: utc(2026, 12, 28), isTripStay: false),
        ]
        var series = [
            measurement(lat: 38, start: utc(2025, 7, 1), tripID: tripA, tempC: 31),
            measurement(lat: 60, start: utc(2025, 2, 1), tempC: -12),
            measurement(lat: 40, start: utc(2025, 7, 20), tempC: 33),
        ]
        var contexts = WeatherEnrichmentPlanner.YearContexts(series)
        expectSameContexts(contexts, as: series)
        #expect(WeatherEnrichmentPlanner.nextCandidate([], contexts: contexts) == nil)
        // A year no candidate is in must leave every scored year untouched.
        let offYear = measurement(lat: 50, start: utc(2023, 7, 1), tempC: 40)
        series.append(offYear)
        contexts.append(offYear)
        // New records each way, near-record and mid-range values, appended as the enricher does.
        let temps: [Double] = [36, -30, 29, 34.5, 12, 45, -41, 22]
        var picks = 0
        while !remaining.isEmpty {
            expectSameContexts(contexts, as: series)
            let incremental = WeatherEnrichmentPlanner.nextCandidate(remaining, contexts: contexts)
            #expect(incremental == WeatherEnrichmentPlanner.nextCandidate(remaining, measurements: series))
            #expect(incremental == WeatherEnrichmentPlanner.rankedQueue(remaining, measurements: series).first)
            guard let top = incremental else { break }
            let picked = remaining.remove(at: top.sourceIndex)
            let measured = WeatherEnrichmentPlanner.Measurement(
                latitude: picked.latitude, longitude: picked.longitude,
                startTime: picked.startTime, endTime: picked.endTime,
                tripID: picked.tripID, avgTemperatureC: temps[picks])
            series.append(measured)
            contexts.append(measured)
            picks += 1
        }
        expectSameContexts(contexts, as: series)
        #expect(picks == 8)
    }

    @Test("with no measurements the queue is the pure seasonal prior: summer and deep-winter stays outrank shoulder-season stays")
    func noMeasurementsMeansPureSeasonalOrder() {
        let julyStay = candidate(lat: 38, start: utc(2026, 7, 10))
        let januaryStay = candidate(lat: 38, start: utc(2026, 1, 10))
        let octoberStay = candidate(lat: 38, start: utc(2026, 10, 10))
        let ranked = WeatherEnrichmentPlanner
            .rankedQueue([octoberStay, julyStay, januaryStay], measurements: [])
            .map(\.candidate.id)
        #expect(ranked.last == octoberStay.id)
        #expect(Set(ranked.prefix(2)) == [julyStay.id, januaryStay.id])
    }

    @Test("a measured record collapses urgency: stays whose ceiling can't reach the record score 0 and fall back to recency order")
    func measuredRecordCollapsesUrgency() {
        // Record 45°C / −40°C: nothing plausible beats either, so both
        // candidates score 0 and the NEWER one ranks first (the enricher's
        // historical newest-first coverage order).
        let older = candidate(lat: 38, start: utc(2026, 7, 1))
        let newer = candidate(lat: 38, start: utc(2026, 7, 20))
        let records = [
            measurement(lat: 30, start: utc(2026, 7, 5), tempC: 45),
            measurement(lat: 60, start: utc(2026, 1, 5), tempC: -40),
        ]
        let ranked = WeatherEnrichmentPlanner.rankedQueue([older, newer], measurements: records)
        #expect(ranked.map(\.candidate.id) == [newer.id, older.id])
        #expect(ranked.allSatisfy { $0.score == 0 })
    }

    @Test("ranking is deterministic on full ties: id.uuidString ascending")
    func deterministicIDTiebreak() {
        let idA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
        let idB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
        let start = utc(2026, 7, 10)
        let a = candidate(id: idA, lat: 38, start: start)
        let b = candidate(id: idB, lat: 38, start: start)
        let forward = WeatherEnrichmentPlanner.rankedQueue([a, b], measurements: []).map(\.candidate.id)
        let backward = WeatherEnrichmentPlanner.rankedQueue([b, a], measurements: []).map(\.candidate.id)
        #expect(forward == [idA, idB])
        #expect(backward == [idA, idB])
    }

    @Test("greedy propagation: a near-record measurement promotes its same-trip neighbor over an otherwise-identical candidate")
    func sameTripNeighborOfTheRecordIsPromoted() {
        let hotTrip = UUID()
        let otherTrip = UUID()
        let records = [
            measurement(lat: 38, start: utc(2026, 7, 5), tripID: hotTrip, tempC: 38),
            // Second trip has a (mild) measurement so neither candidate
            // earns the rain-floor boost — isolates the neighbor term.
            measurement(lat: 38, start: utc(2026, 5, 5), tripID: otherTrip, tempC: 20),
            // A dominant cold record far away, so neither candidate carries
            // residual cold urgency that would mask the heat-side boost.
            measurement(lat: 60, start: utc(2026, 1, 5), tempC: -40),
        ]
        let neighborOfRecord = candidate(lat: 38, start: utc(2026, 7, 10), tripID: hotTrip)
        // Same latitude/season but outside the 5-day spacetime window, so
        // only the same-trip rule separates the two.
        let unrelated = candidate(lat: 38, start: utc(2026, 7, 15), tripID: otherTrip)
        let ranked = WeatherEnrichmentPlanner.rankedQueue(
            [unrelated, neighborOfRecord], measurements: records
        )
        #expect(ranked.first?.candidate.id == neighborOfRecord.id)
        #expect(ranked[0].score > ranked[1].score)
    }

    @Test("cross-trip spacetime neighbor rule: close in time AND distance boosts; far in either does not")
    func crossTripNeighborNeedsBothTimeAndSpaceProximity() {
        let record = measurement(lat: 38, lon: 23.7, start: utc(2026, 7, 5), tempC: 38)
        let nearBoth = candidate(lat: 38.5, lon: 23.9, start: utc(2026, 7, 8))
        let farInTime = candidate(lat: 38.5, lon: 23.9, start: utc(2026, 7, 25))
        let farInSpace = candidate(lat: 38.5, lon: 40.0, start: utc(2026, 7, 8))
        #expect(WeatherEnrichmentPlanner.isNeighbor(nearBoth, record))
        #expect(!WeatherEnrichmentPlanner.isNeighbor(farInTime, record))
        #expect(!WeatherEnrichmentPlanner.isNeighbor(farInSpace, record))
    }

    @Test("neighbor extrema retain exact scores and order for hot and cold frontiers", arguments: [false, true])
    func neighborExtremaPreserveScores(cold: Bool) {
        let tripID = UUID()
        let month = cold ? 1 : 7
        let edge = cold ? -40.0 : 45.0
        let direction = cold ? 1.0 : -1.0
        let records = [
            measurement(lat: 38, start: utc(2026, month, 1), tripID: tripID, tempC: edge + 2 * direction),
            measurement(lat: 80, start: utc(2026, month, 1), tempC: edge),
            measurement(lat: 38, start: utc(2026, month, 1), tripID: tripID, tempC: edge + direction),
            measurement(lat: 80, start: utc(2026, cold ? 7 : 1, 1), tempC: cold ? 45 : -40)
        ]
        let neighbor = candidate(lat: 38, start: utc(2026, month, 15), tripID: tripID, isTripStay: false)
        let unrelated = candidate(lat: 38, start: utc(2026, month, 15), isTripStay: false)
        for measurements in [records, Array(records.reversed())] {
            let ranked = WeatherEnrichmentPlanner.rankedQueue([unrelated, neighbor], measurements: measurements)
            #expect(ranked.map(\.candidate.id) == [neighbor.id, unrelated.id])
            #expect(ranked.map(\.score) == [2, 0])
        }
    }

    @Test("rainiest floor: a trip with zero measured stays outranks an equal candidate in an already-measured trip")
    func unmeasuredTripGetsTheRainFloorBoost() {
        let measuredTrip = UUID()
        let virginTrip = UUID()
        // Dominant far-away records zero out urgency AND keep the mild
        // measured-trip datapoint off both frontiers, so the same-trip
        // neighbor rule can't leak a boost into the comparison — the only
        // differentiator left is the rain floor.
        let context = [
            measurement(lat: 38, start: utc(2026, 5, 5), tripID: measuredTrip, tempC: 20),
            measurement(lat: 30, start: utc(2026, 7, 5), tempC: 45),
            measurement(lat: 60, start: utc(2026, 1, 5), tempC: -40),
        ]
        let inMeasuredTrip = candidate(lat: 38, start: utc(2026, 7, 10), tripID: measuredTrip)
        let inVirginTrip = candidate(lat: 38, start: utc(2026, 7, 10), tripID: virginTrip)
        let ranked = WeatherEnrichmentPlanner.rankedQueue(
            [inMeasuredTrip, inVirginTrip], measurements: context
        )
        #expect(ranked.first?.candidate.id == inVirginTrip.id)
        #expect(ranked[0].score - ranked[1].score == WeatherEnrichmentPlanner.rainFloorBoostC)
    }
}

// MARK: - Extremes-safe stopping rule

struct WeatherPlannerExtremesSafeTests {

    @Test("no measurements at all → never safe (there is nothing to display)")
    func noMeasurementsIsNeverSafe() {
        #expect(!WeatherEnrichmentPlanner.extremesAreSafe(
            unmeasured: [], measuredMaxC: nil, measuredMinC: nil
        ))
        #expect(!WeatherEnrichmentPlanner.extremesAreSafe(
            unmeasured: [candidate(lat: 38, start: utc(2026, 7, 10))],
            measuredMaxC: nil, measuredMinC: nil
        ))
    }

    @Test("everything measured → safe")
    func fullyMeasuredIsSafe() {
        #expect(WeatherEnrichmentPlanner.extremesAreSafe(
            unmeasured: [], measuredMaxC: 31, measuredMinC: 2
        ))
    }

    @Test("coverage-blind honesty: an unmeasured July stay makes a 25°C record unsafe, however high coverage is")
    func unmeasuredSummerStayIsUnsafe() {
        let julyStay = candidate(lat: 38, start: utc(2026, 7, 10))
        #expect(!WeatherEnrichmentPlanner.extremesAreSafe(
            unmeasured: [julyStay], measuredMaxC: 25, measuredMinC: -30
        ))
    }

    @Test("an unmeasured winter stay endangers the coldest record symmetrically")
    func unmeasuredWinterStayIsUnsafeForTheColdRecord() {
        let januaryStay = candidate(lat: 60, start: utc(2026, 1, 10))
        #expect(!WeatherEnrichmentPlanner.extremesAreSafe(
            unmeasured: [januaryStay], measuredMaxC: 45, measuredMinC: 5
        ))
    }

    @Test("the plan's central claim: LOW coverage can be safe — shoulder-season leftovers can't beat dominant measured records")
    func shoulderSeasonLeftoversAreSafe() {
        let octoberStay = candidate(lat: 38, start: utc(2026, 10, 10))
        let aprilStay = candidate(lat: 38, start: utc(2026, 4, 10))
        #expect(WeatherEnrichmentPlanner.extremesAreSafe(
            unmeasured: [octoberStay, aprilStay], measuredMaxC: 45, measuredMinC: -30
        ))
    }
}

// MARK: - YearWrappedGenerator.weatherExtremesSafe (eligibility mirror)

@MainActor
struct WrappedWeatherExtremesSafeGateTests {

    private func makeStay(
        category: StayCategory,
        start: Date,
        lat: Double = 38,
        tempC: Double? = nil,
        conditionRaw: String? = nil
    ) -> Stay {
        let stay = Stay(
            startTime: start, endTime: start.addingTimeInterval(86400),
            centroidLatitude: lat, centroidLongitude: 23.7,
            h3IndexRes6: "861eda747ffffff", pingCount: 3,
            distanceFromHomeKm: 100, pingIDs: []
        )
        stay.category = category
        stay.avgTemperatureC = tempC
        stay.weatherConditionRaw = conditionRaw ?? (tempC != nil ? "clear" : nil)
        return stay
    }

    @Test("dominant measured records + only shoulder-season unmeasured stays → safe")
    func measuredRecordsWithHarmlessLeftoversAreSafe() {
        let stays = [
            makeStay(category: .destination, start: utc(2026, 7, 10), tempC: 45),
            makeStay(category: .destination, start: utc(2026, 1, 10), tempC: -30),
            makeStay(category: .destination, start: utc(2026, 10, 10)),  // unmeasured, harmless
        ]
        #expect(YearWrappedGenerator.weatherExtremesSafe(allStays: stays))
    }

    @Test("an unmeasured July destination stay blocks safety")
    func unmeasuredJulyDestinationBlocks() {
        // The threat stay belongs to a trip: destination and transit threats
        // require trip membership because the enricher fetches no weather
        // for tripless residue. A tripless unmeasured stay not blocking is
        // checked by
        // HomeShapeGateTests.triplessResidueIsInvisibleToStayAggregates.
        let threat = makeStay(category: .destination, start: utc(2026, 7, 10))
        threat.trip = Trip(startDate: threat.startTime)
        let stays = [
            makeStay(category: .destination, start: utc(2026, 6, 10), tempC: 25),
            makeStay(category: .destination, start: utc(2026, 1, 10), tempC: -30),
            threat,  // unmeasured record threat
        ]
        #expect(!YearWrappedGenerator.weatherExtremesSafe(allStays: stays))
    }

    @Test("terminal .unavailable marks are excluded from the threat set (plan risk note)")
    func terminalUnavailableIsExcluded() {
        let stays = [
            makeStay(category: .destination, start: utc(2026, 7, 10), tempC: 45),
            makeStay(category: .destination, start: utc(2026, 1, 10), tempC: -30),
            makeStay(category: .destination, start: utc(2026, 7, 12),
                     conditionRaw: StayWeather.Condition.unavailable.rawValue),
        ]
        #expect(YearWrappedGenerator.weatherExtremesSafe(allStays: stays))
    }

    @Test("pre-WeatherKit-floor stays are excluded (they can never be measured)")
    func preFloorStayIsExcluded() {
        let stays = [
            makeStay(category: .destination, start: utc(2026, 7, 10), tempC: 45),
            makeStay(category: .destination, start: utc(2026, 1, 10), tempC: -30),
            makeStay(category: .destination, start: utc(2019, 7, 10)),  // pre-floor July: never enrichable
        ]
        #expect(YearWrappedGenerator.weatherExtremesSafe(allStays: stays))
    }

    @Test("home stays: an extreme-month one blocks, a shoulder-month one is the accepted blind spot")
    func homeStayEligibilityMirrorsTheEnricher() {
        let measured = [
            makeStay(category: .destination, start: utc(2026, 6, 10), tempC: 25),
            makeStay(category: .destination, start: utc(2026, 1, 10), tempC: -30),
        ]
        let julyHome = makeStay(category: .home, start: utc(2026, 7, 15))
        #expect(!YearWrappedGenerator.weatherExtremesSafe(allStays: measured + [julyHome]))
        // October home stays are outside the enricher's extreme-month window
        // — never measured, so never waited for.
        let octoberHome = makeStay(category: .home, start: utc(2026, 10, 15))
        #expect(YearWrappedGenerator.weatherExtremesSafe(allStays: measured + [octoberHome]))
    }

    @Test("no measurements at all → unsafe, so the card falls back to Top Destinations")
    func noMeasurementsMeansNoCard() {
        let stays = [makeStay(category: .destination, start: utc(2026, 10, 10))]
        #expect(!YearWrappedGenerator.weatherExtremesSafe(allStays: stays))
    }
}

// MARK: - Card-5 gate integration

@MainActor
struct WrappedWeatherCardGateTests {

    /// Stats carrying one renderable superlative, so the content gate is
    /// satisfied and these cases isolate the VERDICT, which is
    /// what they exist to pin.
    private func renderableStats() -> WrappedStats {
        var stats = WrappedStats()
        stats.hottestTempC = 31.4
        stats.hottestLocality = "Ios"
        return stats
    }

    @Test("a safe verdict shows the weather card even at low coverage; an unsafe one hides it even at high coverage")
    func verdictOverridesCoverage() {
        var safeStats = renderableStats()
        safeStats.weatherExtremesSafe = true
        let lowCoverage = WrappedView.visibleCards(
            stats: safeStats, weatherCoverage: 0.2
        )
        #expect(lowCoverage.contains(.weather))
        #expect(!lowCoverage.contains(.topDestinations))

        var unsafeStats = renderableStats()
        unsafeStats.weatherExtremesSafe = false
        let highCoverage = WrappedView.visibleCards(
            stats: unsafeStats, weatherCoverage: 0.95
        )
        #expect(!highCoverage.contains(.weather))
        #expect(highCoverage.contains(.topDestinations))
    }

    /// A safe extreme with no place name renders nothing. The fallback card
    /// must still appear so an empty weather panel does not occupy its slot.
    @Test("a safe verdict with nothing renderable yields the fallback card, not a blank one")
    func safeVerdictWithNoRenderableRowFallsBack() {
        var stats = WrappedStats()
        stats.weatherExtremesSafe = true
        // A measured extreme whose stay never resolved a place name.
        stats.hottestTempC = 31.4
        stats.hottestLocality = nil
        let cards = WrappedView.visibleCards(
            stats: stats, weatherCoverage: 1.0
        )
        #expect(!cards.contains(.weather))
        #expect(cards.contains(.topDestinations))
    }

    @Test("any one renderable superlative earns the card")
    func anySingleSuperlativeEarnsTheCard() {
        var rainOnly = WrappedStats()
        rainOnly.weatherExtremesSafe = true
        rainOnly.rainiestTripName = "Ireland"
        rainOnly.rainiestPrecipitationMm = 88
        #expect(WrappedView.visibleCards(
            stats: rainOnly, weatherCoverage: 0
        ).contains(.weather))

        var coldOnly = WrappedStats()
        coldOnly.weatherExtremesSafe = true
        coldOnly.coldestTempC = -4
        coldOnly.coldestLocality = "Tromso"
        #expect(WrappedView.visibleCards(
            stats: coldOnly, weatherCoverage: 0
        ).contains(.weather))

        // A zero-precipitation "rainiest" trip is not content.
        var noRain = WrappedStats()
        noRain.weatherExtremesSafe = true
        noRain.rainiestTripName = "Cairo"
        noRain.rainiestPrecipitationMm = 0
        #expect(!WrappedView.visibleCards(
            stats: noRain, weatherCoverage: 0
        ).contains(.weather))
    }

    @Test("pre-feature artifacts (nil verdict) keep the legacy 0.7 coverage gate")
    func legacyBlobsKeepTheCoverageGate() {
        let atThreshold = WrappedView.visibleCards(
            stats: renderableStats(), weatherCoverage: 0.7
        )
        #expect(atThreshold.contains(.weather))
        let belowThreshold = WrappedView.visibleCards(
            stats: renderableStats(), weatherCoverage: 0.69
        )
        #expect(!belowThreshold.contains(.weather))
    }

    @Test("the verdict round-trips through the stats blob and tolerates its absence (forward-compat rule)")
    func verdictRoundTripsAndToleratesAbsence() throws {
        var stats = WrappedStats()
        stats.weatherExtremesSafe = true
        let blob = try #require(stats.encoded())
        #expect(WrappedStats.decoded(from: blob)?.weatherExtremesSafe == true)

        // A pre-feature blob (no key) must decode with the verdict nil.
        let legacy = try #require(WrappedStats().encoded())
        var json = try #require(try JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        json.removeValue(forKey: "weatherExtremesSafe")
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let decoded = try #require(WrappedStats.decoded(from: stripped))
        #expect(decoded.weatherExtremesSafe == nil)
    }
}
