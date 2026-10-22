//
//  TransitMode.swift
//  TravelLog
//

import Foundation

/// How the user travelled from the previous stay to this one.
///
/// Persisted as `String` via `Stay.transitFromPreviousRaw` — same pattern
/// as `DataSource` / `StayCategory`: forward-compatible, CloudKit-safe,
/// lightweight-migration-friendly.
///
/// `.flight` is recorded where `FlightJudge` rules out every surface mode
/// with margin or saw the phone in the air, with a scheduled airport serving
/// both ends — see `TransitInferer`. For NEW data that is the only
/// determination made: CoreMotion (which once supplied the ground sub-modes and
/// had no flight/boat class) was removed, so a non-flight leg is recorded as
/// `.unknown`. The ground cases (`.walking`, `.running`, `.cycling`,
/// `.automotive`, `.mixed`, `.stationary`) remain in the enum because older
/// stays and JSON imports still carry those persisted values and the UI renders
/// them.
///
/// `.notFlight` is the user's correction from the Flight Log: "this leg was
/// not a flight". No pass ever writes or revisits it (inference fills only
/// nil legs, the re-passes only `.unknown` ones), so it holds against Detect
/// Flights. Older builds decode it as `.unknown` and their raw `flight`
/// predicates never match it.
nonisolated enum TransitMode: String, Codable, CaseIterable, Sendable {
    case stationary  = "stationary"
    case walking     = "walking"
    case running     = "running"
    case cycling     = "cycling"
    case automotive  = "automotive"
    case flight      = "flight"
    case mixed       = "mixed"
    case unknown     = "unknown"
    case notFlight   = "notFlight"

    static func decode(_ raw: String) -> TransitMode {
        TransitMode(rawValue: raw) ?? .unknown
    }

    var displayName: String {
        switch self {
        case .stationary:
            String(localized: "transit-mode.name.stationary", defaultValue: "Stationary", comment: "Transit mode name.")
        case .walking:
            String(localized: "transit-mode.name.walking", defaultValue: "Walking", comment: "Transit mode name.")
        case .running:
            String(localized: "transit-mode.name.running", defaultValue: "Running", comment: "Transit mode name.")
        case .cycling:
            String(localized: "transit-mode.name.cycling", defaultValue: "Cycling", comment: "Transit mode name.")
        case .automotive:
            String(localized: "transit-mode.name.driving", defaultValue: "Driving", comment: "Transit mode name.")
        case .flight:
            String(localized: "transit-mode.name.flight", defaultValue: "Flight", comment: "Transit mode name.")
        case .mixed:
            String(localized: "transit-mode.name.mixed", defaultValue: "Mixed", comment: "Transit mode name.")
        case .unknown:
            String(localized: "transit-mode.name.unknown", defaultValue: "Unknown", comment: "Transit mode name.")
        case .notFlight:
            String(localized: "transit-mode.name.not-flight", defaultValue: "Not a flight", comment: "Transit mode name for a leg the user said was not a flight.")
        }
    }

    var systemImage: String {
        switch self {
        case .stationary: "figure.stand"
        case .walking:    "figure.walk"
        case .running:    "figure.run"
        case .cycling:    "bicycle"
        case .automotive: "car.fill"
        case .flight:     "airplane"
        case .mixed:      "arrow.triangle.branch"
        case .unknown:    "questionmark.circle"
        case .notFlight:  "road.lanes"
        }
    }
}
