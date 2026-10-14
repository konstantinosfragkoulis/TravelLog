//
//  TripSplitHint.swift
//  TravelLog
//

import Foundation

/// Decides when a reconstructed trip should surface the existing split feature.
///
/// Imported evidence can contain long gaps between different places without a
/// qualifying home stay between them. The pipeline must keep that evidence as
/// one trip because it cannot know whether the user took one journey or several;
/// this hint exposes that ambiguity without changing the assembly rules.
///
/// Frequency contract: the hint may appear for at most `maxDistinctTrips`
/// DISTINCT trips ever (a ledger of seen trip IDs, not a counter — a counter
/// keyed on "last shown trip" over-consumed slots on A→B→A navigation and
/// refused a previously seen trip at the cap), and never again once the user
/// dismisses it or performs a split. The ledger is bounded by construction:
/// it can never grow past `maxDistinctTrips` entries.
nonisolated enum TripSplitHint {

    /// UserDefaults keys (device-local; deliberately NOT synced, and
    /// deliberately NOT reset by Delete All Data — this is feature-education
    /// history, not travel data).
    nonisolated static let dismissedKey = "splitHintDismissed_v1"
    nonisolated static let seenTripIDsKey = "splitHintSeenTripIDs_v1"
    nonisolated static let maxDistinctTrips = 3
    nonisolated static let minInterStayGap: TimeInterval = 48 * 3600

    /// Value inputs only — no @Model access.
    nonisolated static func isEligible(
        isComplete: Bool,
        userEdited: Bool,
        stays: [StaySignal]
    ) -> Bool {
        guard isComplete, !userEdited else { return false }
        guard stays.contains(where: \.isImported) else { return false }

        let destinationLocalities = Set(stays.compactMap { stay -> String? in
            guard stay.isDestination,
                  let locality = stay.locality,
                  !locality.isEmpty else { return nil }
            return locality
        })
        guard destinationLocalities.count >= 2 else { return false }

        let orderedStays = stays.sorted { $0.startTime < $1.startTime }
        return zip(orderedStays, orderedStays.dropFirst()).contains { previous, next in
            next.startTime.timeIntervalSince(previous.endTime) >= minInterStayGap
        }
    }

    nonisolated struct StaySignal {
        let startTime: Date
        let endTime: Date
        let isDestination: Bool
        let locality: String?
        let isImported: Bool
    }

    /// One atomic presentation claim over the persisted ledger. Pure so the
    /// sequence semantics are unit-testable; the caller performs the
    /// read-claim-write against UserDefaults synchronously on the MainActor
    /// (after the settle delay), which serializes concurrent scenes.
    ///
    /// Rules: ineligible or dismissed never presents; a trip already in the
    /// ledger may always re-present (re-opening it never burns another
    /// slot); a new trip presents only while the ledger has capacity, and
    /// claims its slot by joining the ledger.
    nonisolated static func claimPresentation(
        eligible: Bool,
        dismissed: Bool,
        seenIDs: [UUID],
        tripID: UUID
    ) -> (present: Bool, updatedSeenIDs: [UUID]) {
        guard eligible, !dismissed else { return (false, seenIDs) }
        if seenIDs.contains(tripID) { return (true, seenIDs) }
        guard seenIDs.count < maxDistinctTrips else { return (false, seenIDs) }
        return (true, seenIDs + [tripID])
    }

    /// Ledger persistence: comma-joined `uuidString`s, order-preserving.
    /// Unparseable segments are dropped (a corrupt default degrades to
    /// showing the hint again, never to crashing or blocking).
    nonisolated static func decodeSeenIDs(_ raw: String) -> [UUID] {
        raw.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
    }

    nonisolated static func encodeSeenIDs(_ ids: [UUID]) -> String {
        ids.map(\.uuidString).joined(separator: ",")
    }
}
