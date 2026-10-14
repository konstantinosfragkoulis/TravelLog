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

/// Capability classification + the device-local unavailable→available
/// transition latch that arms the upgrade experience.
///
/// Persistence is deliberately UserDefaults (NOT iCloud-synced): capability
/// is a per-device fact. A device restore carries UserDefaults over, so a
/// user restoring a non-FM phone's backup onto an FM phone lands with a
/// stored non-available state — the first capability check on the new phone
/// observes the transition and latches.
///
/// A fresh install has no stored state, so its FIRST observation never
/// latches. It can still latch on a LATER one: on a new
/// FM-capable device, or right after an OS update, the first observation is
/// commonly `.waitingForModel` while the model downloads — that gets stored,
/// and when the download finishes the guard in `recordCurrentState` is
/// satisfied and `becameAvailableAt` is stamped. This is benign (the upgrade
/// card additionally gates on a heuristic backlog, which a fresh device has
/// none of), but it matters when reading `becameAvailableAt` as EVIDENCE:
/// a stamp does not prove a restore happened, and it never indicates a failed
/// FM call — availability and call outcomes are separate signals. The
/// Settings "Enhance History" row is the backlog-driven catch-all regardless.
nonisolated enum FMCapability {
    static let lastKnownStateKey = "lastKnownFMCapability_v1"
    static let becameAvailableAtKey = "fmBecameAvailableAt_v1"

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

    /// Locale-specific form used by multilingual title generation. Keeping
    /// this check beside the availability seam prevents UI and generation
    /// call sites from maintaining hard-coded Apple Intelligence language
    /// lists that age differently across OS releases.
    static func supportsLocale(_ locale: Locale) -> Bool {
        SystemLanguageModel.default.supportsLocale(locale)
    }

    /// Records the observed state and latches the unavailable→available
    /// transition. Returns `true` only on the firing observation.
    ///
    /// The latch is one-shot per device: thermal or toggle flapping after
    /// the first transition must not re-arm upgrade prompts. A `nil` stored
    /// state (fresh install) records without latching — there is no known
    /// "before" to have transitioned from.
    @discardableResult
    static func recordCurrentState(
        _ state: FMCapabilityState = FMCapability.current,
        defaults: UserDefaults = .standard,
        at date: Date = .now
    ) -> Bool {
        let storedRaw = defaults.string(forKey: lastKnownStateKey)
        defaults.set(state.rawValue, forKey: lastKnownStateKey)

        guard state == .available,
              let storedRaw,
              FMCapabilityState(rawValue: storedRaw) != .available,
              defaults.object(forKey: becameAvailableAtKey) == nil else {
            return false
        }
        defaults.set(date, forKey: becameAvailableAtKey)
        return true
    }

    /// When this device first gained FM after not having it — nil if that
    /// transition was never observed here.
    static func becameAvailableAt(defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: becameAvailableAtKey) as? Date
    }
}
