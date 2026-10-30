//
//  FMCapabilityTests.swift
//  TravelLogTests
//
//  Foundation-level coverage for `FMCapability` — the
//  tri-state availability classifier: a pure mapping of every constructible
//  `SystemLanguageModel.Availability` value to an `FMCapabilityState`.
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
}
