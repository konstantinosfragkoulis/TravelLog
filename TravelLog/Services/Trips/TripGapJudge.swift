//
//  TripGapJudge.swift
//  TravelLog
//

import Foundation

/// Decides whether two consecutive away stays with no home evidence between
/// them belong to one trip. Imported history (photos above all) leaves gaps
/// with no observation at all, so "no qualifying home stay between" is not
/// proof of being away. The judge reads only what the two sides say: whether
/// the place changed, how long the gap is, and whether home was reachable and
/// roughly on the way. A gap it cannot call is `.unsure`: only the user knows,
/// so the caller asks rather than guesses.
nonisolated enum TripGapJudge {

    nonisolated enum Verdict: Equatable, Sendable {
        case sameTrip
        case separateTrips
        /// Home was reachable but off the direct route: a question for the user.
        case unsure
    }

    /// One side of the gap: where the earlier stay ended or the later one began.
    nonisolated struct Side: Sendable {
        let latitude: Double
        let longitude: Double
        let distanceFromHomeKm: Double
        let time: Date
    }

    /// Both sides closer than this are the same place: the user stayed put.
    static let samePlaceKm: Double = 25
    /// Staying put this long without one observation still ends the trip.
    static let samePlaceMaxGap: TimeInterval = 21 * 86_400
    /// Moving on after this long without one observation ends the trip.
    static let movedMaxGap: TimeInterval = 7 * 86_400
    /// The route through home is at most this much longer than the direct
    /// one: going from one side to the other passes home.
    static let passesHomeDetour: Double = 1.15
    /// Spare hours at home that make a return plausible when home is near,
    /// not on, the route.
    static let homeNightSpare: TimeInterval = 6 * 3600
    static let nearRouteDetour: Double = 1.6

    static func verdict(after earlier: Side, before later: Side) -> Verdict {
        let gap = later.time.timeIntervalSince(earlier.time)
        let directKm = HomeOrbit.greatCircleKm(
            earlier.latitude, earlier.longitude, later.latitude, later.longitude)
        if directKm < samePlaceKm {
            return gap >= samePlaceMaxGap ? .separateTrips : .sameTrip
        }
        if gap >= movedMaxGap { return .separateTrips }
        let spare = gap - travelTime(km: earlier.distanceFromHomeKm)
            - travelTime(km: later.distanceFromHomeKm)
        guard spare >= 0 else { return .sameTrip }
        let detour = (earlier.distanceFromHomeKm + later.distanceFromHomeKm) / max(directKm, 1)
        if detour <= passesHomeDetour { return .separateTrips }
        if detour > nearRouteDetour { return .sameTrip }
        return spare >= homeNightSpare ? .separateTrips : .unsure
    }

    /// A deliberately fast door-to-door estimate: overland under 400 km, a
    /// flight with its overhead beyond. Fast travel makes a visit home look
    /// easier, so the judge errs towards asking, never towards inventing a stay.
    static func travelTime(km: Double) -> TimeInterval {
        let hours = km < 400 ? 0.5 + km / 100 : 3 + km / 800
        return hours * 3600
    }
}
