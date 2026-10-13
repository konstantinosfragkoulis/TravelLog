//
//  FMCapabilityTests.swift
//  TravelLogTests
//
//  Foundation-level coverage for `FMCapability` — the
//  tri-state availability classifier + the device-local
//  unavailable→available transition latch that arms the upgrade experience.
//
//  Two seams:
//    - `classify(_:)`: pure mapping of every constructible
//      `SystemLanguageModel.Availability` value to an `FMCapabilityState`.
//    - `recordCurrentState(_:defaults:at:)` / `becameAvailableAt(defaults:)`:
//      the one-shot latch semantics, exercised against throwaway
//      `UserDefaults(suiteName:)` stores so nothing touches `.standard`.
//
//  `@unknown default → .unknownUnavailable` is not directly testable (an
//  unknown enum case can't be constructed), but every shipping reason is.
//
//  `@MainActor` to match the target's MainActor-by-default convention; the
//  types under test are `nonisolated`, so this is only for consistency.
//

import Testing
import Foundation
import FoundationModels
@testable import TravelLog

@MainActor
struct FMCapabilityTests {

    // MARK: - Helpers

    /// A fresh, uniquely-named suite per call — guarantees isolation even under
    /// parallel scheduling. Cleared on creation for good measure.
    private func freshDefaults() -> (defaults: UserDefaults, name: String) {
        let name = "FMCapabilityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    // MARK: - classify(_:) mapping

    @Test("available → .available")
    func classifyAvailable() {
        #expect(FMCapability.classify(.available) == .available)
    }

    @Test("unavailable(.deviceNotEligible) → .ineligible (permanent)")
    func classifyDeviceNotEligible() {
        let state = FMCapability.classify(.unavailable(.deviceNotEligible))
        #expect(state == .ineligible)
        #expect(state.isPermanentlyIneligible)
        #expect(!state.isTransientlyUnavailable)
    }

    @Test("unavailable(.appleIntelligenceNotEnabled) → .disabledByUser (transient)")
    func classifyAINotEnabled() {
        let state = FMCapability.classify(.unavailable(.appleIntelligenceNotEnabled))
        #expect(state == .disabledByUser)
        #expect(!state.isPermanentlyIneligible)
        #expect(state.isTransientlyUnavailable)
    }

    @Test("unavailable(.modelNotReady) → .waitingForModel (transient)")
    func classifyModelNotReady() {
        let state = FMCapability.classify(.unavailable(.modelNotReady))
        #expect(state == .waitingForModel)
        #expect(!state.isPermanentlyIneligible)
        #expect(state.isTransientlyUnavailable)
    }

    // MARK: - recordCurrentState latch semantics

    @Test("fresh install (nil stored) records the state but never latches")
    func recordFreshInstallNoLatch() {
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        // No known "before" to transition from → records, returns false.
        let latched = FMCapability.recordCurrentState(.available, defaults: defaults)
        #expect(latched == false)
        #expect(FMCapability.becameAvailableAt(defaults: defaults) == nil)
        #expect(defaults.string(forKey: FMCapability.lastKnownStateKey) == "available")
    }

    @Test("stored non-available → available latches exactly once")
    func recordLatchesOnceOnTransition() {
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        // Seed a non-available "before" (itself does not latch — nil prior).
        #expect(FMCapability.recordCurrentState(.ineligible, defaults: defaults) == false)

        // First available observation is the firing transition.
        let first = FMCapability.recordCurrentState(.available, defaults: defaults)
        #expect(first == true)
        #expect(FMCapability.becameAvailableAt(defaults: defaults) != nil)

        // A second available observation must NOT re-fire.
        let second = FMCapability.recordCurrentState(.available, defaults: defaults)
        #expect(second == false)
    }

    @Test("available → unavailable → available again does not re-latch (one-shot)")
    func recordDoesNotReLatchOnFlapping() {
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(FMCapability.recordCurrentState(.disabledByUser, defaults: defaults) == false)
        #expect(FMCapability.recordCurrentState(.available, defaults: defaults) == true)
        let firstDate = FMCapability.becameAvailableAt(defaults: defaults)
        #expect(firstDate != nil)

        // Flap back to unavailable, then available once more.
        #expect(FMCapability.recordCurrentState(.disabledByUser, defaults: defaults) == false)
        let reLatch = FMCapability.recordCurrentState(.available, defaults: defaults)
        #expect(reLatch == false)
        // The latch date is untouched by the second transition.
        #expect(FMCapability.becameAvailableAt(defaults: defaults) == firstDate)
    }

    @Test("becameAvailableAt round-trips the exact latch date")
    func becameAvailableAtRoundTrip() {
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let when = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(FMCapability.recordCurrentState(.ineligible, defaults: defaults) == false)
        #expect(FMCapability.recordCurrentState(.available, defaults: defaults, at: when) == true)
        #expect(FMCapability.becameAvailableAt(defaults: defaults) == when)
    }

    @Test("a non-available observation is always stored and never latches")
    func recordUnavailableNeverLatches() {
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(FMCapability.recordCurrentState(.waitingForModel, defaults: defaults) == false)
        #expect(FMCapability.recordCurrentState(.ineligible, defaults: defaults) == false)
        #expect(FMCapability.becameAvailableAt(defaults: defaults) == nil)
        #expect(defaults.string(forKey: FMCapability.lastKnownStateKey) == "ineligible")
    }
}
