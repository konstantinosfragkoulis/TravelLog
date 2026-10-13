//
//  TripSplitHintTests.swift
//  TravelLogTests
//

import Foundation
import Testing
@testable import TravelLog

@MainActor
struct TripSplitHintTests {

    private let base = Date(timeIntervalSince1970: 1_779_958_400)

    private func stay(
        startHour: Double,
        durationHours: Double = 1,
        isDestination: Bool = true,
        locality: String? = "Athens",
        isImported: Bool = true
    ) -> TripSplitHint.StaySignal {
        let start = base.addingTimeInterval(startHour * 3600)
        return TripSplitHint.StaySignal(
            startTime: start,
            endTime: start.addingTimeInterval(durationHours * 3600),
            isDestination: isDestination,
            locality: locality,
            isImported: isImported
        )
    }

    private func isEligible(
        isComplete: Bool = true,
        userEdited: Bool = false,
        stays: [TripSplitHint.StaySignal]
    ) -> Bool {
        TripSplitHint.isEligible(
            isComplete: isComplete,
            userEdited: userEdited,
            stays: stays
        )
    }

    private var eligibleStays: [TripSplitHint.StaySignal] {
        [
            stay(startHour: 0, locality: "Athens"),
            stay(startHour: 50, locality: "Paris"),
        ]
    }

    @Test func completeUneditedImportedTripWithDistinctDestinationsAndLongGapIsEligible() {
        #expect(isEligible(stays: eligibleStays))
    }

    @Test func ongoingTripIsNotEligible() {
        #expect(!isEligible(isComplete: false, stays: eligibleStays))
    }

    @Test func userEditedTripIsNotEligible() {
        #expect(!isEligible(userEdited: true, stays: eligibleStays))
    }

    @Test func tripWithoutImportedStaysIsNotEligible() {
        let stays = [
            stay(startHour: 0, locality: "Athens", isImported: false),
            stay(startHour: 50, locality: "Paris", isImported: false),
        ]
        #expect(!isEligible(stays: stays))
    }

    @Test func tripWithOnlyOneDestinationLocalityIsNotEligible() {
        let stays = [
            stay(startHour: 0, locality: "Athens"),
            stay(startHour: 50, isDestination: false, locality: "Paris"),
        ]
        #expect(!isEligible(stays: stays))
    }

    @Test func twoDestinationStaysWithTheSameLocalityAreNotEligible() {
        let stays = [
            stay(startHour: 0, locality: "Athens"),
            stay(startHour: 50, locality: "Athens"),
        ]
        #expect(!isEligible(stays: stays))
    }

    @Test func nilAndEmptyDestinationLocalitiesDoNotCountAsDistinct() {
        let stays = [
            stay(startHour: 0, locality: "Athens"),
            stay(startHour: 50, locality: nil),
            stay(startHour: 100, locality: ""),
        ]
        #expect(!isEligible(stays: stays))
    }

    @Test func fortySevenHourGapIsNotEligible() {
        let stays = [
            stay(startHour: 0, locality: "Athens"),
            stay(startHour: 48, locality: "Paris"),
        ]
        #expect(!isEligible(stays: stays))
    }

    @Test func unsortedStaysAreSortedBeforeGapEvaluation() {
        #expect(isEligible(stays: Array(eligibleStays.reversed())))
    }

    @Test func mixedImportedAndLiveStaysAreEligible() {
        // One imported stay is enough evidence: `contains` also covers mixed
        // imported and live stays. Separate all-imported and all-live fixtures
        // would leave the mixed case untested.
        let stays = [
            stay(startHour: 0, locality: "Athens", isImported: false),
            stay(startHour: 50, locality: "Paris", isImported: true),
        ]
        #expect(isEligible(stays: stays))
    }

    @Test func exactlyFortyEightHourGapIsEligible() {
        // The threshold is inclusive (`>=`).
        let stays = [
            stay(startHour: 0, locality: "Athens"),
            stay(startHour: 49, locality: "Paris"),
        ]
        #expect(isEligible(stays: stays))
    }

    // MARK: - Presentation ledger

    @Test func capIsExactlyThreeDistinctTrips() {
        // Literal pin: changing the cap must fail a test, not silently
        // reshape the product promise.
        #expect(TripSplitHint.maxDistinctTrips == 3)
    }

    @Test func dismissedHintIsNeverPresented() {
        let claim = TripSplitHint.claimPresentation(
            eligible: true, dismissed: true, seenIDs: [], tripID: UUID())
        #expect(!claim.present)
        #expect(claim.updatedSeenIDs.isEmpty)
    }

    @Test func ineligibleTripIsNeverPresentedEvenWhenAlreadySeen() {
        let tripID = UUID()
        let claim = TripSplitHint.claimPresentation(
            eligible: false, dismissed: false, seenIDs: [tripID], tripID: tripID)
        #expect(!claim.present)
    }

    @Test func dismissedTripIsNeverPresentedEvenWhenAlreadySeen() {
        let tripID = UUID()
        let claim = TripSplitHint.claimPresentation(
            eligible: true, dismissed: true, seenIDs: [tripID], tripID: tripID)
        #expect(!claim.present)
    }

    @Test func newTripUnderTheCapClaimsASlot() {
        let tripID = UUID()
        let seen = [UUID(), UUID()]
        let claim = TripSplitHint.claimPresentation(
            eligible: true, dismissed: false, seenIDs: seen, tripID: tripID)
        #expect(claim.present)
        #expect(claim.updatedSeenIDs == seen + [tripID])
    }

    @Test func newTripAtTheCapIsNotPresented() {
        let claim = TripSplitHint.claimPresentation(
            eligible: true, dismissed: false,
            seenIDs: [UUID(), UUID(), UUID()], tripID: UUID())
        #expect(!claim.present)
        #expect(claim.updatedSeenIDs.count == 3)
    }

    @Test func revisitingASeenTripNeverBurnsAnotherSlot() {
        // A → B → A: after A's revisit the ledger still holds two entries
        // and C can still claim the third. A last-shown-trip counter would
        // incorrectly count A's revisit as a new entry.
        let a = UUID(), b = UUID(), c = UUID()
        var seen: [UUID] = []
        for trip in [a, b, a, c] {
            let claim = TripSplitHint.claimPresentation(
                eligible: true, dismissed: false, seenIDs: seen, tripID: trip)
            #expect(claim.present)
            seen = claim.updatedSeenIDs
        }
        #expect(seen == [a, b, c])
    }

    @Test func seenTripStillPresentsAtTheCapRegardlessOfRecency() {
        // A → B → C fills the ledger; reopening A (not the most recent)
        // must still present without growing the ledger.
        let a = UUID(), b = UUID(), c = UUID()
        let claim = TripSplitHint.claimPresentation(
            eligible: true, dismissed: false, seenIDs: [a, b, c], tripID: a)
        #expect(claim.present)
        #expect(claim.updatedSeenIDs == [a, b, c])
    }

    @Test func ledgerRoundTripsThroughEncoding() {
        let ids = [UUID(), UUID(), UUID()]
        #expect(TripSplitHint.decodeSeenIDs(TripSplitHint.encodeSeenIDs(ids)) == ids)
        #expect(TripSplitHint.decodeSeenIDs("") == [])
    }

    @Test func corruptLedgerSegmentsAreDroppedNotFatal() {
        let id = UUID()
        let raw = "garbage,\(id.uuidString),,also-not-a-uuid"
        #expect(TripSplitHint.decodeSeenIDs(raw) == [id])
    }
}
