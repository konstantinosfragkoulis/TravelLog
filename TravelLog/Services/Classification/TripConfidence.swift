//
//  TripConfidence.swift
//  TravelLog
//

import Foundation

/// Grade excursions by distance beyond home and duration.
///
/// ```
/// score = log₂(1 + D/D*) × (1 + log₂(1 + T/T*))
/// ```
///
/// - `D`  — kilometres beyond the home **shape** (`HomeShape.distanceKm`), 0 inside.
/// - `T`  — hours of the excursion containing the stay.
/// - `D*` — the shape's area-equivalent radius, the per-user distance scale.
/// - `T*` — 24 h, the day cycle. Astronomical, not tuned.
///
/// D must gate T: no duration can promote a stay that never left ordinary range.
/// Derive θ at the natural scales, score(D*, T*) = 2; question the model before tuning the threshold.
nonisolated enum TripConfidence {

    /// `T*` — the day cycle.
    static let durationScaleHours: Double = 24

    /// `θ` — see the type doc. Derived, not fitted.
    static let threshold: Double = 2.0

    /// The score for one (distance, duration) pair against one home's scale.
    /// Returns 0 for any point inside the shape, whatever the duration.
    static func score(
        distanceKm: Double, durationHours: Double, scaleKm: Double
    ) -> Double {
        guard distanceKm > 0, scaleKm > 0 else { return 0 }
        let duration = max(0, durationHours)
        let distanceTerm = log2(1 + distanceKm / scaleKm)
        let durationTerm = 1 + log2(1 + duration / durationScaleHours)
        return distanceTerm * durationTerm
    }

    /// Score an excursion against every active home and take the **lowest**
    /// result — the most home-like reading wins.
    ///
    /// Score each home separately: union area would inflate D* and suppress trips near another home.
    ///
    /// No homes ⇒ 0. A user with no declared home has no trips, which is
    /// correct: everything is unknown, not everything is travel.
    static func score(
        latitude: Double, longitude: Double, durationHours: Double,
        shapes: [HomeShape]
    ) -> Double {
        guard !shapes.isEmpty else { return 0 }
        return shapes.map { shape in
            score(distanceKm: shape.distanceKm(toLatitude: latitude, longitude: longitude),
                  durationHours: durationHours,
                  scaleKm: shape.areaEquivalentRadiusKm)
        }.min() ?? 0
    }

    // MARK: - Excursions

    /// One stay, reduced to what excursion formation needs.
    struct StayInput: Sendable, Equatable {
        let id: UUID
        let start: Date
        let end: Date
        let latitude: Double
        let longitude: Double
        /// Airport / port / station. See `Excursion` for why these are neutral.
        let isTransitNode: Bool

        init(id: UUID, start: Date, end: Date, latitude: Double, longitude: Double,
             isTransitNode: Bool) {
            self.id = id
            self.start = start
            self.end = max(start, end)
            self.latitude = latitude
            self.longitude = longitude
            self.isTransitNode = isTransitNode
        }
    }

    /// An in-shape stay beside an excursion, kept so HomeOrbit can witness a
    /// same-day return. Confidence scoring never reads it.
    struct HomeBracket: Sendable, Equatable {
        let stayID: UUID
        let start: Date
        let end: Date
    }

    /// A maximal run of away-from-home stays that never spans an `unknown`
    /// interval. An in-shape stay, an `unknown` gap or the end of input closes
    /// it; only the first is presence at home, so an open or unknown-closed
    /// run is scored the same but carries no `homeReturn`.
    struct Excursion: Sendable, Equatable {
        let stays: [StayInput]
        /// `D` — the furthest any stay in the run reached beyond the shape.
        let distanceKm: Double
        /// `T` — hours from the run's first start to its last end.
        let durationHours: Double
        let score: Double
        /// The in-shape stay that ended latest before the run's first stay,
        /// when the interval between them is `.observed`. Nil when none
        /// precedes the run, or an `unknown` gap separates them.
        let departure: HomeBracket?
        /// The in-shape stay whose start closed the run. Nil when an
        /// `unknown` gap or the end of input closed it.
        let homeReturn: HomeBracket?
        /// False when no membership existed throughout the run, so no home
        /// scored it. `score` and `distanceKm` are then 0 as placeholders, not
        /// "near home": callers read this flag before the score.
        let hasScoringMembership: Bool

        init(stays: [StayInput], distanceKm: Double, durationHours: Double,
             score: Double, departure: HomeBracket? = nil,
             homeReturn: HomeBracket? = nil, hasScoringMembership: Bool = true) {
            self.stays = stays
            self.distanceKm = distanceKm
            self.durationHours = durationHours
            self.score = score
            self.departure = departure
            self.homeReturn = homeReturn
            self.hasScoringMembership = hasScoringMembership
        }

        var isTrip: Bool { score >= TripConfidence.threshold }
        var start: Date { stays.first?.start ?? .distantPast }
        var end: Date { stays.last?.end ?? .distantPast }

        /// The earliest `end` at which this excursion would clear θ if only
        /// its duration kept growing — the accretion case, where clustering
        /// extends the last stay's `endTime` ping by ping without minting a
        /// new stay. The score is separable (a distance term times a duration
        /// term), so the home that minimises it never changes as duration
        /// grows and the crossing is closed-form:
        ///
        ///     distanceTerm × (1 + log₂(1 + T*/24)) = θ
        ///     T* = 24 × (2^(θ / distanceTerm − 1) − 1)
        ///
        /// `accretionMarginSeconds` is added so floating-point slack can never
        /// report a crossing the exact score then denies (which would re-arm
        /// the back half on every pass right at the boundary). Nil when the
        /// excursion already clears, when no dwell can lift it (distance term
        /// 0 — inside every shape, or no membership), or when the crossing
        /// lies beyond `accretionHorizonHours`.
        var accretionClearsAt: Date? {
            guard !isTrip, score > 0 else { return nil }
            let durationTerm = 1 + log2(1 + max(0, durationHours) / TripConfidence.durationScaleHours)
            let distanceTerm = score / durationTerm
            guard distanceTerm > 0 else { return nil }
            let requiredDurationTerm = TripConfidence.threshold / distanceTerm
            let requiredHours = TripConfidence.durationScaleHours
                * (pow(2, requiredDurationTerm - 1) - 1)
            guard requiredHours.isFinite,
                  requiredHours <= TripConfidence.accretionHorizonHours else { return nil }
            return start.addingTimeInterval(
                requiredHours * 3600 + TripConfidence.accretionMarginSeconds)
        }
    }

    /// See `Excursion.accretionClearsAt`.
    static let accretionMarginSeconds: TimeInterval = 60
    /// A crossing further out than this is treated as "never by dwell alone":
    /// no single stay accretes for a year, so the fingerprint need not track it.
    static let accretionHorizonHours: Double = 365 * 24

    /// Form excursions from chronological stays. Transit nodes join runs but do not set their maximum distance.
    /// When transit nodes are the ONLY evidence, score them normally rather than erasing the run.
    /// Unknown intervals terminate runs: PresenceEvidence gaps longer than a week are neither presence nor absence.
    /// Each excursion records its home brackets (see `Excursion`); they never change its stays or score.
    static func excursions(from stays: [StayInput], shapes: [HomeShape]) -> [Excursion] {
        excursions(from: stays, memberships: shapes.map { HomeMembership(seed: $0) })
    }

    /// Membership containment and distance use each stay’s time; valid orbit discs split runs like seed shapes.
    /// D* always remains the seed scale (HomeMembership.scaleKm).
    /// A dated membership scores only the runs its era spans; a run no membership spans is unscored.
    static func excursions(
        from stays: [StayInput], memberships: [HomeMembership]
    ) -> [Excursion] {
        guard !memberships.isEmpty else { return [] }
        let ordered = stays.sorted {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }

        func isInsideAnyShape(_ stay: StayInput) -> Bool {
            memberships.contains {
                $0.contains(latitude: stay.latitude, longitude: stay.longitude,
                            at: stay.start)
            }
        }

        var runs: [(stays: [StayInput], departure: HomeBracket?,
                    homeReturn: HomeBracket?)] = []
        var current: [StayInput] = []
        var reach: Date?
        var departure: HomeBracket?
        // The in-shape stay with the latest end so far. An unknown closure
        // clears it: no departure is certified across a hole in the record.
        var lastHome: HomeBracket?

        func closeRun(homeReturn: HomeBracket?) {
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
            // Containment is tested for EVERY stay, transit node or not.
            // Neutrality suppresses a node's influence on distance; it does not
            // punch a hole in the shape, so someone who works at an airport
            // inside their own urban centre is still home.
            if isInsideAnyShape(stay) {
                let bracket = HomeBracket(stayID: stay.id, start: stay.start,
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
            // `D` ignores neutral stays — an airport must not set how far a
            // trip reached — EXCEPT when they are the only evidence, where
            // demoting them to nothing would erase the run entirely.
            let nonNeutral = run.filter { !$0.isTransitNode }
            let anchors = nonNeutral.isEmpty ? run : nonNeutral
            guard let first = run.first, let last = run.max(by: { $0.end < $1.end }),
                  !anchors.isEmpty else { return nil }
            let durationHours = last.end.timeIntervalSince(first.start) / 3600
            var distance = 0.0
            var best = Double.greatestFiniteMagnitude
            var scored = false
            for membership in memberships {
                // A home that did not exist throughout the run is no reading for
                // it: the run cannot be errands around a home that had ended, or
                // had not begun, while part of it happened. Transit counts here
                // although it sets no distance. A membership with no era always exists.
                guard run.allSatisfy({ membership.isValid(at: $0.start) }) else { continue }
                scored = true
                var shapeDistance = 0.0
                for stay in anchors {
                    shapeDistance = max(shapeDistance, membership.distanceKm(
                        toLatitude: stay.latitude, longitude: stay.longitude,
                        at: stay.start))
                }
                let value = score(distanceKm: shapeDistance,
                                  durationHours: durationHours,
                                  scaleKm: membership.scaleKm)
                if value < best { best = value; distance = shapeDistance }
            }
            return Excursion(stays: run, distanceKm: distance,
                             durationHours: durationHours,
                             score: best == .greatestFiniteMagnitude ? 0 : best,
                             departure: entry.departure,
                             homeReturn: entry.homeReturn,
                             hasScoringMembership: scored)
        }
    }
}
