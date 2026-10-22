//
//  FlightTimeOverrides.swift
//  TravelLog
//
//  The departure and arrival times the user set for a flight in the
//  Flight Log.
//

import Foundation

/// The user's own times for a flight. Location data only brackets a flight
/// between the last fix at the origin and the first at the destination, so
/// a gap in the data (a dead battery, a layover) reads as a very long
/// window. Times set here replace the derived ones in the log's dates, the
/// flight's duration (instead of the distance estimate) and the overnight
/// mark (`FlightRecord.userDeparture`).
///
/// Keyed by the ARRIVAL stay's UUID, the same identity as `FlightRecord.id`
/// and `FlightCandidateDismissals`, so an edit survives recomputes and a
/// Reclassify-All (which preserves stay ids). It lives outside the stay row,
/// so no pass that writes a leg's mode or distance can touch it. Device-local
/// like the dismissals (no schema entity): the backup's preferences carry it
/// and Delete All Data clears it. An entry applies only while it fits the
/// leg's current window (`fits`); one that no longer fits (a later import
/// moved the leg) is kept, unapplied, and never lends its times to another
/// journey.
///
/// Stored as one string list, newest last ("<uuid> <departure> <arrival>",
/// whole seconds since 1970), so the backup's answer-list merge carries it;
/// when the list names a flight twice, the later entry wins.
nonisolated enum FlightTimeOverrides {
    static let defaultsKey = "flightTimeOverrides_v1"

    nonisolated struct Times: Sendable, Equatable, Codable {
        let departure: Date
        let arrival: Date

        var duration: TimeInterval { arrival.timeIntervalSince(departure) }
    }

    /// Shorter than any scheduled hop with its taxi time.
    static let minimumDuration: TimeInterval = 15 * 60
    /// The longest nonstop is under 20 h; this leaves room for a journey
    /// the user keeps as one flight across a layover.
    static let maximumDuration: TimeInterval = 48 * 60 * 60
    /// How far either time may sit outside the observed window: a stay's
    /// end can trail the takeoff, and the next one's start lead the
    /// landing, when a fix from the climb or the descent joined it.
    static let windowSlack: TimeInterval = 3 * 60 * 60

    /// The instants either time may take: the observed window (the last fix
    /// at the origin to the first at the destination) widened by
    /// `windowSlack`. With no origin fix, the window reaches back the
    /// longest duration from the arrival.
    static func allowedRange(windowStart: Date?, windowEnd: Date) -> ClosedRange<Date> {
        let start = min(windowStart ?? windowEnd.addingTimeInterval(-maximumDuration), windowEnd)
        return start.addingTimeInterval(-windowSlack)...windowEnd.addingTimeInterval(windowSlack)
    }

    /// Arrival after departure by a flight's duration, both inside the
    /// allowed range.
    static func fits(_ times: Times, windowStart: Date?, windowEnd: Date) -> Bool {
        let range = allowedRange(windowStart: windowStart, windowEnd: windowEnd)
        return hasValidDuration(times)
            && range.contains(times.departure) && range.contains(times.arrival)
    }

    static func hasValidDuration(_ times: Times) -> Bool {
        let duration = times.duration
        return duration.isFinite && duration >= minimumDuration && duration <= maximumDuration
    }

    /// Where the editor starts for a flight with no times set: landing at
    /// the first fix at the destination, after the distance estimate in the
    /// air, never before the last fix at the origin unless that would leave
    /// less than a flight's minimum.
    static func suggested(windowStart: Date?, windowEnd: Date, estimatedHours: Double) -> Times {
        let estimate = clampedDuration(hours: estimatedHours)
        var departure = windowEnd.addingTimeInterval(-estimate)
        if let windowStart, windowStart > departure,
           windowEnd.timeIntervalSince(windowStart) >= minimumDuration {
            departure = windowStart
        }
        departure = max(departure, allowedRange(windowStart: windowStart, windowEnd: windowEnd).lowerBound)
        return Times(departure: departure, arrival: windowEnd)
    }

    /// The data's gap from which "When did you fly?" asks which end the
    /// flight sat at: the bound past which the average speed tells nothing.
    static let questionMinimumGap: TimeInterval = 24 * 60 * 60

    /// The question's first answer: taking off at the last fix at the
    /// origin, landing the estimate later, never past the first fix at the
    /// destination unless that would leave less than a flight's minimum.
    /// The second answer, landing at the first fix, is `suggested`.
    static func afterLeaving(windowStart: Date, windowEnd: Date, estimatedHours: Double) -> Times {
        var arrival = min(windowStart.addingTimeInterval(clampedDuration(hours: estimatedHours)), windowEnd)
        if arrival.timeIntervalSince(windowStart) < minimumDuration {
            arrival = windowStart.addingTimeInterval(minimumDuration)
        }
        return Times(departure: windowStart, arrival: arrival)
    }

    /// An estimate in hours as a duration a flight may take.
    static func clampedDuration(hours: Double) -> TimeInterval {
        hours.isFinite ? min(max(hours * 3600, minimumDuration), maximumDuration) : minimumDuration
    }

    // MARK: Storage

    static func all(defaults: UserDefaults = .standard) -> [UUID: Times] {
        var result: [UUID: Times] = [:]
        for entry in defaults.stringArray(forKey: defaultsKey) ?? [] {
            guard let parsed = parse(entry) else { continue }
            result[parsed.id] = parsed.times
        }
        return result
    }

    static func times(for id: UUID, defaults: UserDefaults = .standard) -> Times? {
        all(defaults: defaults)[id]
    }

    /// Replaces the flight's entry (every earlier one for its id goes).
    static func set(_ times: Times, for id: UUID, defaults: UserDefaults = .standard) {
        var raw = withoutEntries(for: id, defaults: defaults)
        raw.append(entry(id: id, times: times))
        defaults.set(raw, forKey: defaultsKey)
    }

    /// Back to the derived times.
    static func clear(_ id: UUID, defaults: UserDefaults = .standard) {
        let raw = defaults.stringArray(forKey: defaultsKey) ?? []
        let kept = withoutEntries(for: id, defaults: defaults)
        guard kept.count != raw.count else { return }
        if kept.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(kept, forKey: defaultsKey)
        }
    }

    static func entry(id: UUID, times: Times) -> String {
        let departure = Int64(times.departure.timeIntervalSince1970.rounded())
        let arrival = Int64(times.arrival.timeIntervalSince1970.rounded())
        return "\(id.uuidString) \(departure) \(arrival)"
    }

    /// nil for an entry this build cannot read or whose times are no
    /// flight's (a restored file is not trusted): every reader skips it.
    static func parse(_ entry: String) -> (id: UUID, times: Times)? {
        let parts = entry.split(separator: " ")
        guard parts.count == 3,
              let id = UUID(uuidString: String(parts[0])),
              let departure = Int64(parts[1]), let arrival = Int64(parts[2]) else { return nil }
        let times = Times(departure: Date(timeIntervalSince1970: TimeInterval(departure)),
                          arrival: Date(timeIntervalSince1970: TimeInterval(arrival)))
        guard hasValidDuration(times) else { return nil }
        return (id, times)
    }

    private static func withoutEntries(for id: UUID, defaults: UserDefaults) -> [String] {
        let prefix = id.uuidString + " "
        return (defaults.stringArray(forKey: defaultsKey) ?? []).filter { !$0.hasPrefix(prefix) }
    }
}
