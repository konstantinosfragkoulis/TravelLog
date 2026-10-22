//
//  WeatherEnrichmentPlanner.swift
//  TravelLog
//

import Foundation
import CoreLocation

/// Pure scoring for WHERE the daily WeatherKit budget gets spent.
/// The passport/Wrapped weather
/// superlatives are only as correct as the set of stays that happen to be
/// measured when they're computed, so this planner orders the un-enriched
/// backlog extreme-first: a crude hemisphere-aware seasonal prior ("look in
/// the summer"), a greedy neighbor boost around near-record measurements
/// (weather is spatiotemporally autocorrelated), and a per-trip floor so the
/// rainiest-trip card gets at least one datapoint per trip.
///
/// **Inference only prioritizes; it never reaches
/// the UI as a number.** Superlatives always display measured WeatherKit
/// values — the planner just makes the true extremes get measured early. The
/// same seasonal model powers `extremesAreSafe`, the Wrapped weather card's
/// honesty gate ("no un-enriched stay could plausibly beat the measured
/// extremes"), which replaces the blunt ≥ 0.7 coverage gate for new
/// artifacts.
///
/// The climate prior is deliberately coarse (a latitude-linear annual mean
/// plus a latitude-scaled sinusoidal season, ± a generous spread). It is
/// used only to ORDER a queue and to bound "could this stay beat the
/// record" — never displayed — so bias toward generous bounds is the safe
/// direction (too-wide bounds waste budget; too-narrow ones let a wrong
/// card through).
///
/// Everything here is deterministic for a given input (sorted tiebreaks,
/// fixed UTC calendar frame).
nonisolated enum WeatherEnrichmentPlanner {

    // MARK: - Inputs

    /// Value snapshot of an un-enriched stay. Crosses the `PipelineGate`
    /// boundary in `WeatherEnricher`, so no `@Model` reference.
    struct Candidate: Sendable, Equatable {
        let id: UUID
        let latitude: Double
        let longitude: Double
        let startTime: Date
        let endTime: Date
        let tripID: UUID?
        /// destination/transit (true) vs home/routine (false).
        let isTripStay: Bool
    }

    /// Value snapshot of an already-measured stay (has `avgTemperatureC`).
    struct Measurement: Sendable, Equatable {
        let latitude: Double
        let longitude: Double
        let startTime: Date
        let endTime: Date
        let tripID: UUID?
        let avgTemperatureC: Double
    }

    // MARK: - Tuning constants

    /// Safety margin for the stopping rule / extremes-safe gate:
    /// an un-enriched stay is dangerous while its seasonal
    /// ceiling reaches within this margin of the measured record.
    static let safetyMarginC: Double = 3

    /// Half-width of the plausible band around the seasonal expectation.
    /// Generous on purpose — it must cover heat waves and microclimates,
    /// because the extremes-safe gate treats anything outside the band as
    /// impossible.
    static let priorSpreadC: Double = 10

    /// Neighbor rule: a measurement promotes a candidate in
    /// the same trip, or within this time gap AND distance across trips.
    static let neighborMaxGapSeconds: TimeInterval = 5 * 86400
    static let neighborMaxDistanceKm: Double = 300

    /// Additive boost for a trip stay whose trip has NO measured stay yet —
    /// the rainiest-trip card is a per-trip superlative, so every trip needs
    /// at least one datapoint (per-trip floors, not global extremes).
    static let rainFloorBoostC: Double = 4

    /// Months in which home/routine stays are worth measuring (record
    /// temperatures live in summer/winter) — the same Jun–Aug/Dec–Feb rule
    /// `WeatherEnricher` has always applied, hoisted here so the enricher's
    /// eligibility filter and the Wrapped safety gate can't drift apart.
    static let extremeHomeMonths: Set<Int> = [6, 7, 8, 12, 1, 2]

    // MARK: - Seasonal climate prior

    /// Crude expected stay-average temperature (°C) for a latitude/month:
    /// an annual mean that decays linearly poleward of 10°, plus a
    /// latitude-scaled seasonal sinusoid peaking in July (northern
    /// hemisphere) or January (southern). Equatorial latitudes get almost no
    /// seasonality; they are heat candidates year-round.
    static func annualMeanC(latitude: Double) -> Double {
        27.0 - 0.55 * max(0, min(90, abs(latitude)) - 10)
    }

    static func expectedAvgTempC(latitude: Double, month: Int) -> Double {
        let amplitude = 0.32 * min(90, abs(latitude))
        let hottestMonth = latitude >= 0 ? 7 : 1
        let rawDistance = abs(month - hottestMonth)
        let monthsFromHottest = Double(min(rawDistance, 12 - rawDistance))
        return annualMeanC(latitude: latitude) + amplitude * cos(monthsFromHottest * .pi / 6)
    }

    /// Hottest this stay's average could plausibly be.
    static func seasonalCeilingC(latitude: Double, month: Int) -> Double {
        expectedAvgTempC(latitude: latitude, month: month) + priorSpreadC
    }

    /// Coldest this stay's average could plausibly be.
    static func seasonalFloorC(latitude: Double, month: Int) -> Double {
        expectedAvgTempC(latitude: latitude, month: month) - priorSpreadC
    }

    // MARK: - Ranking

    /// The source index identifies a physical input row, even for identical UUID twins.
    struct RankedCandidate: Sendable, Equatable {
        let sourceIndex: Int
        let candidate: Candidate
        let score: Double
    }

    /// Candidates ordered by budget priority, highest first, with scores.
    /// Deterministic: score ↓, then `endTime` ↓ (recency — score-0 tails
    /// degrade to the enricher's historical newest-first order), then
    /// `id.uuidString` ↑.
    ///
    /// Measurements are grouped by UTC calendar year and each candidate is
    /// scored against ITS OWN year's extremes — superlatives are per-year
    /// artifacts, so a record measured in 2025 says nothing about whether a
    /// 2026 stay still needs measuring.
    static func rankedQueue(
        _ candidates: [Candidate],
        measurements: [Measurement]
    ) -> [RankedCandidate] {
        scoredCandidates(candidates, contexts: YearContexts(measurements)).sorted(by: ranksBefore)
    }

    /// The next request is selected linearly; callers rerank after each new measurement.
    static func nextCandidate(
        _ candidates: [Candidate],
        measurements: [Measurement]
    ) -> RankedCandidate? {
        nextCandidate(candidates, contexts: YearContexts(measurements))
    }

    /// Same selection against contexts the caller keeps across appended measurements.
    static func nextCandidate(
        _ candidates: [Candidate],
        contexts: YearContexts
    ) -> RankedCandidate? {
        scoredCandidates(candidates, contexts: contexts).reduce(nil) { best, candidate in
            guard let best else { return candidate }
            return ranksBefore(candidate, best) ? candidate : best
        }
    }

    private static func scoredCandidates(
        _ candidates: [Candidate],
        contexts: YearContexts
    ) -> [RankedCandidate] {
        candidates.enumerated().map { index, candidate in
            let context = contexts.byYear[yearUTC(of: candidate.startTime)] ?? YearContext(measurements: [])
            return RankedCandidate(sourceIndex: index, candidate: candidate,
                                   score: priorityScore(candidate, context: context))
        }
    }

    private static func ranksBefore(_ a: RankedCandidate, _ b: RankedCandidate) -> Bool {
        if a.score != b.score { return a.score > b.score }
        if a.candidate.endTime != b.candidate.endTime { return a.candidate.endTime > b.candidate.endTime }
        return a.candidate.id.uuidString < b.candidate.id.uuidString
    }

    /// Per-year measured state a candidate is scored against.
    struct YearContext: Sendable {
        let measuredMaxC: Double?
        let measuredMinC: Double?
        /// Near-record measurements (within `safetyMarginC` of the year max/
        /// min) — the only ones whose neighborhoods are worth promoting.
        let hotFrontier: [Measurement]
        let coldFrontier: [Measurement]
        let tripIDsWithMeasurement: Set<UUID>

        init(measurements: [Measurement]) {
            let maxC = measurements.map(\.avgTemperatureC).max()
            let minC = measurements.map(\.avgTemperatureC).min()
            measuredMaxC = maxC
            measuredMinC = minC
            hotFrontier = maxC.map { top in
                measurements.filter { $0.avgTemperatureC > top - safetyMarginC }
            } ?? []
            coldFrontier = minC.map { bottom in
                measurements.filter { $0.avgTemperatureC < bottom + safetyMarginC }
            } ?? []
            tripIDsWithMeasurement = Set(measurements.compactMap(\.tripID))
        }
    }

    /// Year contexts of a measurement series. Appending rebuilds only the new
    /// row's year from that year's rows in series order, so every context
    /// equals the one regrouping the extended series would build.
    struct YearContexts: Sendable {
        private var rowsByYear: [Int: [Measurement]]
        private(set) var byYear: [Int: YearContext]

        init(_ measurements: [Measurement]) {
            let grouped = Dictionary(grouping: measurements) { yearUTC(of: $0.startTime) }
            rowsByYear = grouped
            byYear = grouped.mapValues { YearContext(measurements: $0) }
        }

        mutating func append(_ measurement: Measurement) {
            let year = yearUTC(of: measurement.startTime)
            rowsByYear[year, default: []].append(measurement)
            byYear[year] = YearContext(measurements: rowsByYear[year, default: []])
        }
    }

    /// Budget-priority score, in °C-headroom units. `max(heat, cold)` of:
    ///
    ///   urgency        = how far the candidate's seasonal ceiling (floor)
    ///                    reaches past the measured record − margin; 0 once
    ///                    the prior says it can't plausibly beat the record.
    ///                    With NO measurement yet the year is wide open —
    ///                    the latitude's annual mean stands in as the
    ///                    reference, so the ordering collapses to pure
    ///                    seasonal extremeness (July and deep-January stays
    ///                    rank symmetrically ahead of shoulder months).
    ///   neighborBoost  = greedy propagation: a near-record
    ///                    measurement promotes its trip/spacetime neighbors,
    ///                    scaled by how close it sits to the record. (The
    ///                    difference `maxNeighborTemp -
    ///                    currentYearMax` is never positive — neighbors ARE
    ///                    part of the year max — so the margin is added to
    ///                    make the frontier actually promote.)
    ///
    /// plus `rainFloorBoostC` when the candidate's trip has no measurement.
    static func priorityScore(_ candidate: Candidate, context: YearContext) -> Double {
        let month = monthUTC(of: candidate.startTime)
        let ceiling = seasonalCeilingC(latitude: candidate.latitude, month: month)
        let floor = seasonalFloorC(latitude: candidate.latitude, month: month)

        let noMeasurementReference = annualMeanC(latitude: candidate.latitude)
        let maxRef = context.measuredMaxC ?? noMeasurementReference
        let minRef = context.measuredMinC ?? noMeasurementReference

        var heat = max(0, ceiling - (maxRef - safetyMarginC))
        var cold = max(0, (minRef + safetyMarginC) - floor)

        if let maxC = context.measuredMaxC,
           let hottestNeighbor = context.hotFrontier.lazy
               .filter({ isNeighbor(candidate, $0) })
               .map(\.avgTemperatureC).max() {
            heat += max(0, hottestNeighbor + safetyMarginC - maxC)
        }
        if let minC = context.measuredMinC,
           let coldestNeighbor = context.coldFrontier.lazy
               .filter({ isNeighbor(candidate, $0) })
               .map(\.avgTemperatureC).min() {
            cold += max(0, minC + safetyMarginC - coldestNeighbor)
        }

        var score = max(heat, cold)
        if candidate.isTripStay,
           let tripID = candidate.tripID,
           !context.tripIDsWithMeasurement.contains(tripID) {
            score += rainFloorBoostC
        }
        return score
    }

    /// Same trip, or closer than ~5 days AND ~300 km across trips.
    static func isNeighbor(_ candidate: Candidate, _ measurement: Measurement) -> Bool {
        if let candidateTrip = candidate.tripID, candidateTrip == measurement.tripID {
            return true
        }
        let gap = max(
            0,
            max(candidate.startTime.timeIntervalSince(measurement.endTime),
                measurement.startTime.timeIntervalSince(candidate.endTime))
        )
        guard gap < neighborMaxGapSeconds else { return false }
        let from = CLLocation(latitude: candidate.latitude, longitude: candidate.longitude)
        let to = CLLocation(latitude: measurement.latitude, longitude: measurement.longitude)
        return from.distance(from: to) / 1000.0 < neighborMaxDistanceKm
    }

    // MARK: - Extremes-safe gate

    /// True when the measured hottest/coldest can be displayed as the year's
    /// records: some measurement exists AND no un-enriched (still
    /// enrichable) stay's seasonal band reaches within `safetyMarginC` of
    /// either record. This is the greedy loop's stopping rule, reused as the
    /// Wrapped weather card's render gate — strictly better than coverage %
    /// (50% coverage can be safe when all the summer stays are measured; 90%
    /// can be unsafe when the missing 10% is July).
    ///
    /// Callers pass only stays the enricher would ever measure (terminal
    /// `.unavailable` marks, pre-WeatherKit-floor stays, and non-extreme-
    /// month home/routine stays are excluded by design — the same accepted
    /// blind spot the enrichment eligibility rules have always had).
    static func extremesAreSafe(
        unmeasured: [Candidate],
        measuredMaxC: Double?,
        measuredMinC: Double?
    ) -> Bool {
        guard let maxC = measuredMaxC, let minC = measuredMinC else { return false }
        for candidate in unmeasured {
            let month = monthUTC(of: candidate.startTime)
            if seasonalCeilingC(latitude: candidate.latitude, month: month) >= maxC - safetyMarginC {
                return false
            }
            if seasonalFloorC(latitude: candidate.latitude, month: month) <= minC + safetyMarginC {
                return false
            }
        }
        return true
    }

    // MARK: - Calendar frame

    /// UTC gregorian, matching the year windows `YearWrappedGenerator` and
    /// the stay-fetch predicates use.
    private static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    static func monthUTC(of date: Date) -> Int {
        utcCalendar.component(.month, from: date)
    }

    static func yearUTC(of date: Date) -> Int {
        utcCalendar.component(.year, from: date)
    }
}
