//
//  FMCapability.swift
//  TravelLog
//

import Foundation
import FoundationModels

/// Tri-state classification of Foundation Models availability.
///
/// Every FM call site keeps its own binary `.available` check (correct for
/// "should I call FM right now"). This type answers the OTHER questions:
/// how should UI frame the absence, and is it worth deferring a durable
/// write because availability is only *transiently* gone (model still
/// downloading, Apple Intelligence toggled off) versus gone forever
/// (hardware ineligible)?
nonisolated enum FMCapabilityState: String, Codable, Sendable {
    /// Foundation Models is ready.
    case available
    /// Supported hardware, model still downloading — transient.
    case waitingForModel
    /// Apple Intelligence is off in Settings — user-actionable, transient.
    case disabledByUser
    /// This hardware can never run Foundation Models.
    case ineligible
    /// A reason this build doesn't know. Treated as transient (the
    /// conservative choice: never tell a user their device is incapable
    /// based on an unrecognized signal).
    case unknownUnavailable

    var isPermanentlyIneligible: Bool { self == .ineligible }

    var isTransientlyUnavailable: Bool {
        self == .waitingForModel || self == .disabledByUser || self == .unknownUnavailable
    }
}

/// Capability classification and locale support for the Foundation Models
/// calendar tie-breaker.
nonisolated enum FMCapability {
    /// Pure classifier — the testable seam.
    static func classify(_ availability: SystemLanguageModel.Availability) -> FMCapabilityState {
        if case .available = availability { return .available }
        guard case .unavailable(let reason) = availability else { return .unknownUnavailable }
        switch reason {
        case .deviceNotEligible:
            return .ineligible
        case .appleIntelligenceNotEnabled:
            return .disabledByUser
        case .modelNotReady:
            return .waitingForModel
        @unknown default:
            return .unknownUnavailable
        }
    }

    /// Live capability, re-read on every access (availability can flip at
    /// any time — model download finishing, the user toggling Apple
    /// Intelligence — so nothing caches it; matches the per-call policy of
    /// the FM features themselves).
    static var current: FMCapabilityState {
        classify(SystemLanguageModel.default.availability)
    }

    /// Live locale support, kept behind the same Foundation Models capability
    /// seam as `current` so production callers never reach into
    /// `SystemLanguageModel` directly and tests can inject their own verdict.
    static func supportsCurrentLocale() -> Bool {
        SystemLanguageModel.default.supportsLocale(.current)
    }
}
