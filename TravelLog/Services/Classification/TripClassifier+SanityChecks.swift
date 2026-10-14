//
//  TripClassifier+SanityChecks.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import Foundation
import CryptoKit
import SwiftData
import CoreLocation
import FoundationModels
import WidgetKit
import os.log

extension TripClassifier {

    // MARK: - Stage 2.5: Sanity Checks

    /// Assembly requires destination stays to belong to trips and home/routine stays to remain tripless.
    /// Unassigned transit is legitimate residue; suppressed destinations that are not user-overridden
    /// are also valid while their fingerprints excuse them, including dwell growth below the known crossing time.
    /// Fetch errors return true to run the back half; internal for steady-state tests.
    func assemblyInvariantViolated() -> Bool {
        let unassignedDescriptor = FetchDescriptor<Stay>(predicate: #Predicate {
            $0.categoryRaw == "destination" && $0.trip == nil
        })
        guard let unassigned = try? modelContext.fetch(unassignedDescriptor) else { return true }
        if unassigned.contains(where: { stay in
            // The gate always admits a group containing an overridden stay, so a stale fingerprint cannot excuse it.
            if stay.userOverridden { return true }
            guard let fingerprint = gateSuppressedStayFingerprints[stay.id] else { return true }
            return !fingerprint.excuses(
                startTime: stay.startTime,
                endTime: stay.endTime,
                distanceFromHomeKm: stay.distanceFromHomeKm,
                centroidLatitude: stay.centroidLatitude,
                centroidLongitude: stay.centroidLongitude,
                isAirport: stay.isAirport)
        }) {
            return true
        }
        // Only a memo that excuses a stay rests on the digest. One left over from a pass
        // whose stays have all gone (assembly returns early then, keeping the memo)
        // excuses nothing, so a stale digest beside it must not re-arm every pass.
        // Without a temporary home both sides are nil and no stay is read.
        if !unassigned.isEmpty {
            guard let temporaryHomes = try? fetchRequiredTemporaryHomes() else { return true }
            var current: SHA256.Digest?
            if !temporaryHomes.isEmpty {
                let triplessDescriptor = FetchDescriptor<Stay>(predicate: #Predicate {
                    $0.trip == nil && ($0.categoryRaw == "destination" || $0.categoryRaw == "transit")
                })
                // The gate's rings as assembly read them; a failed read is not an empty one.
                let overrides: [HomeAreaOverride]
                do {
                    #if DEBUG
                    if failInvariantOverrideFetchForTesting { throw CocoaError(.fileReadUnknown) }
                    #endif
                    overrides = try modelContext.fetch(FetchDescriptor<HomeAreaOverride>())
                } catch {
                    return true
                }
                guard let tripless = try? modelContext.fetch(triplessDescriptor),
                      let anchors = try? fetchRequiredAnchors() else { return true }
                current = Self.suppressionInputDigest(
                    rings: withShapes(anchors.map { Self.HomeRing($0) }, overrides: overrides),
                    stays: tripless)
            }
            if current != gateSuppressionInputDigest { return true }
        }

        let misattachedDescriptor = FetchDescriptor<Stay>(predicate: #Predicate {
            ($0.categoryRaw == "home" || $0.categoryRaw == "routine") && $0.trip != nil
        })
        guard let misattached = try? modelContext.fetchCount(misattachedDescriptor) else { return true }
        return misattached > 0
    }

    /// Clustering can change sanity inputs without unclassifying stays. These predicates MUST mirror
    /// sanityCheckClassifications, including user-override exemptions; fetch errors run the back half.
    func sanityFixpointViolated() -> Bool {
        let fiveDaysInMinutes = 5 * 24 * 60
        let twentyFourHoursInMinutes = 24 * 60
        let longTransit = FetchDescriptor<Stay>(predicate: #Predicate {
            $0.categoryRaw == "transit" && $0.durationMinutes >= fiveDaysInMinutes
                && $0.userOverridden == false
        })
        guard let long = try? modelContext.fetch(longTransit) else { return true }

        let airportDestination = FetchDescriptor<Stay>(predicate: #Predicate {
            $0.categoryRaw == "destination" && $0.isAirport == true
                && $0.durationMinutes < twentyFourHoursInMinutes
                && $0.userOverridden == false
        })
        guard let airport = try? modelContext.fetch(airportDestination) else { return true }

        let blipDestination = FetchDescriptor<Stay>(predicate: #Predicate {
            $0.categoryRaw == "destination" && $0.durationMinutes <= 20
                && $0.userOverridden == false
        })
        guard let blip = try? modelContext.fetch(blipDestination) else { return true }
        let violating = long + airport + blip
        guard !violating.isEmpty else { return false }

        // The sanity pass changes a copy only when its logical stay's deciding copy
        // violates, so judge each violating UUID among the same copies it groups.
        let ids = Set(violating.map(\.id))
        guard let copies = try? modelContext.fetch(FetchDescriptor<Stay>(
            predicate: #Predicate { ids.contains($0.id) })) else { return true }
        return Self.logicalClassificationRepresentatives(copies.filter(Self.isSanityCandidate))
            .values.contains { Self.sanityCorrection(for: $0) != nil }
    }

    /// Detect closure after home dwell grows without changing category;
    /// read-only mirror of closeStaleOpenTrips, failing open on fetch errors.
    internal func openTripClosureDue() -> Bool {
        var openDescriptor = FetchDescriptor<Trip>(
            predicate: #Predicate { $0.isComplete == false })
        // Every open trip's stays are read: one batched fetch, not a fault per stay.
        openDescriptor.relationshipKeyPathsForPrefetching = [\.stays]
        guard let openTrips = try? modelContext.fetch(openDescriptor) else { return true }
        guard !openTrips.isEmpty else { return false }
        // Only home stays starting at/after the earliest open trip's last
        // stay can close anything — bound the fetch so this arm stays cheap
        // on every pass of a long trip (Stage 4 scans the full home table,
        // but only when the back half actually runs).
        let tripEnds = openTrips.compactMap { $0.orderedStays.last?.endTime }
        guard let earliestEnd = tripEnds.min() else { return false }
        let homeDescriptor = FetchDescriptor<Stay>(
            predicate: #Predicate { $0.categoryRaw == "home" && $0.startTime >= earliestEnd },
            sortBy: [SortDescriptor(\.startTime, order: .forward)])
        guard let homes = try? modelContext.fetch(homeDescriptor) else { return true }
        let qualifying = homes.filter(isQualifyingHomeBoundary)
        guard !qualifying.isEmpty else { return false }
        return openTrips.contains { trip in
            guard let last = trip.orderedStays.last else { return false }
            return qualifying.contains { $0.startTime >= last.endTime }
        }
    }

    /// Detect provisional transit admission after accretion without a category change; fail open on fetch errors.
    /// Mirror provisionalTailVerdict: require the newest linked ping to be live because extension
    /// does not restamp a photo-import or merged stay's source. Bound candidates by endTime freshness.
    internal func provisionalOpenDue() -> Bool {
        let freshSince = Date.now.addingTimeInterval(-Self.fastPathFreshnessSeconds)
        let descriptor = FetchDescriptor<Stay>(predicate: #Predicate {
            $0.categoryRaw == "transit" && $0.trip == nil && $0.pingCount >= 2
                && $0.endTime >= freshSince
        })
        guard let candidates = try? modelContext.fetch(descriptor) else { return true }
        return candidates.contains {
            newestWitnessPing(for: $0)?.source.isLiveObservation == true
        }
    }

    func newestWitnessPing(for stay: Stay) -> LocationPing? {
        let pingIDs = stay.pingIDs
        guard !pingIDs.isEmpty else { return nil }
        var descriptor = FetchDescriptor<LocationPing>(
            predicate: #Predicate { pingIDs.contains($0.id) },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    #if DEBUG
    /// Test seam for routine reconciliation without the pipeline latch or model inference.
    func applyRoutinePlaceChangeCoreForTesting(placeID: UUID) -> CoverageReconciliationOutcome {
        applyRoutinePlaceChangeCore(placeID: placeID)
    }

    func assemblyInvariantViolatedForTesting() -> Bool { assemblyInvariantViolated() }

    /// Test seam for sanity-threshold parity and convergence after one corrective pass.
    func sanityFixpointViolatedForTesting() -> Bool { sanityFixpointViolated() }
    #endif

    /// Fix obvious classification errors that the AI or heuristic got wrong,
    /// using the conservative thresholds documented at Stage 2a (which MUST
    /// mirror these exactly). User-overridden stays are never modified (the
    /// predicate filters them out). Only the category changes —
    /// `continuesPreviousTrip` is left alone because trip boundaries are about
    /// whether the user went home, not what happened at a particular stop.
    /// Same-UUID copies are one logical stay: its deciding copy is judged, and
    /// its correction reaches every copy still in the category it corrects.
    /// A corrected stay's owning trip gets its summary recomputed and its
    /// `aiGeneratedTitle` cleared (Stage 5 regenerates under `.greedy`
    /// sampling). Returns the number of stays corrected, or -1 when the stay
    /// read fails (nothing is mutated before it).
    func sanityCheckClassifications() -> Int {
        let predicate = #Predicate<Stay> {
            ($0.categoryRaw == "destination" || $0.categoryRaw == "transit") &&
            $0.userOverridden == false
        }
        let descriptor = FetchDescriptor<Stay>(predicate: predicate)

        let stays: [Stay]
        do {
            #if DEBUG
            if failSanityFetchForTesting { throw CocoaError(.fileReadUnknown) }
            #endif
            stays = try modelContext.fetch(descriptor)
        } catch {
            logger.error("Sanity check skipped; stays unreadable: \(error.localizedDescription)")
            return -1
        }
        guard !stays.isEmpty else { return 0 }

        var corrected = 0
        var affectedTrips: [ObjectIdentifier: Trip] = [:]
        // Decide every logical stay before changing any copy.
        let corrections = Self.logicalClassificationRepresentatives(stays).compactMapValues { deciding in
            Self.sanityCorrection(for: deciding).map { (from: deciding.category, to: $0) }
        }

        for stay in stays {
            guard let correction = corrections[stay.id], stay.category == correction.from else { continue }
            logger.info("Sanity: \(correction.from.rawValue, privacy: .public) → \(correction.to.rawValue, privacy: .public) for \(stay.locality ?? "?", privacy: .private) (\(stay.durationMinutes)min)")
            stay.category = correction.to
            if let trip = stay.trip {
                affectedTrips[ObjectIdentifier(trip)] = trip
            }
            corrected += 1
        }

        // Recompute summaries for any trips whose stays changed category.
        // Also clear `aiGeneratedTitle` so Stage 5 regenerates — a category
        // flip changes which stays count as destinations, so the title's
        // input has changed even if its text might happen to stay the same
        // (greedy sampling will reproduce identical titles for unchanged
        // semantic inputs).
        if !affectedTrips.isEmpty {
            for trip in affectedTrips.values where !trip.isDeleted {
                TripTitleStore.invalidateGeneratedTitles(
                    for: trip, in: modelContext)
                recomputeBackHalfSummary(trip)
                clearSessionTitleFailures(trip.id)
                clearPersistentTitleFailure(trip.id)
            }
            logger.info("Recomputed summaries (+ cleared AI titles) for \(affectedTrips.count) trip(s) affected by sanity checks.")
        }

        return corrected
    }

    /// A stay the sanity pass reads: classified destination or transit, not user-overridden.
    private static func isSanityCandidate(_ stay: Stay) -> Bool {
        (stay.category == .destination || stay.category == .transit) && !stay.userOverridden
    }

    /// The category the sanity pass moves `stay` to, or nil when its duration fits its category.
    private static func sanityCorrection(for stay: Stay) -> StayCategory? {
        switch stay.category {
        case .transit:
            // 5 days = 7200 minutes. No legitimate transit lasts this long.
            return stay.durationMinutes >= 5 * 24 * 60 ? .destination : nil
        case .destination:
            // 20 minutes with SLC data = a single ping's brief stop. The airport
            // threshold is identical to the heuristic rule.
            let blip = stay.durationMinutes <= 20
            let airport = stay.isAirport && stay.durationMinutes < 24 * 60
            return blip || airport ? .transit : nil
        default:
            return nil
        }
    }

    #if DEBUG
    /// Test seam returning Sendable title values from this actor's unsaved context; a fresh context cannot see them.
    func aiTitleFieldsForTesting(
        _ tripID: UUID
    ) -> (title: String?, localizedCount: Int)? {
        let id = tripID
        let predicate = #Predicate<Trip> { $0.id == id }
        guard let trip = try? modelContext.fetch(FetchDescriptor<Trip>(predicate: predicate)).first else {
            return nil
        }
        return (
            trip.aiGeneratedTitle,
            (trip.localizedTitles ?? []).filter { !$0.isDeleted }.count)
    }

    func canonicalTitleForTesting(
        tripID: UUID,
        tripIdentifier: PersistentIdentifier? = nil
    ) -> String? {
        fetchTrip(
            tripID: tripID,
            tripIdentifier: tripIdentifier)?.aiGeneratedTitle
    }

    /// Test seam exposing departure-home distance stamps from this actor's unsaved context.
    func stayHomeDistancesForTesting() -> [UUID: Double] {
        let stays = (try? modelContext.fetch(FetchDescriptor<Stay>())) ?? []
        return Dictionary(stays.map { ($0.id, $0.distanceFromHomeKm) },
                          uniquingKeysWith: { first, _ in first })
    }

    /// Test seam returning Sendable snapshots from this actor's unsaved context, ordered by startDate; @Models cannot cross actors.
    func assembledTripsForTesting() -> [(id: UUID, isComplete: Bool, hasEndDate: Bool, endDate: Date?, startDate: Date, userEdited: Bool, orders: [Int?])] {
        let trips = (try? modelContext.fetch(FetchDescriptor<Trip>())) ?? []
        return trips
            .sorted { $0.startDate < $1.startDate }
            .map { trip in
                let orders = trip.orderedStays.map { $0.orderInTrip }
                return (trip.id, trip.isComplete, trip.endDate != nil, trip.endDate, trip.startDate, trip.userEdited, orders)
            }
    }

    var lastPipelineMadeChangesForTesting: Bool { lastPipelineMadeChanges }

    /// Test seam exercising provenance with this actor's models, avoiding cross-context @Model transfer.
    func classifyUnclassifiedWithHeuristicsForTesting() -> Int {
        let raw = StayCategory.unclassified.rawValue
        let descriptor = FetchDescriptor<Stay>(predicate: #Predicate { $0.categoryRaw == raw })
        let stays = (try? modelContext.fetch(descriptor)) ?? []
        return classifyWithHeuristics(stays: stays)
    }

    /// Test seam mirroring the non-FM resolution, heuristic, and sanity sequence in one context so neighbour decisions remain visible.
    func runDeterministicClassificationForTesting() -> (resolved: Int, heuristic: Int, corrected: Int) {
        let raw = StayCategory.unclassified.rawValue
        let descriptor = FetchDescriptor<Stay>(
            predicate: #Predicate { $0.categoryRaw == raw },
            sortBy: [SortDescriptor(\.startTime, order: .forward)]
        )
        let stays = (try? modelContext.fetch(descriptor)) ?? []
        // Credit heuristics as stage2aCreditsAsFM does when FM is unavailable.
        let (resolved, ambiguous) = resolveDeterministicOutcomes(stays)
        registerStage2aProvenance(resolved, asFM: false)
        let heuristic = classifyWithHeuristics(stays: ambiguous)
        let corrected = sanityCheckClassifications()
        return (resolved.count, heuristic, corrected)
    }

    /// Test seam exposing membership and restored identity from this actor's unsaved context; nil means absent.
    func tripStayIDsForTesting(_ tripID: UUID) -> Set<UUID>? {
        let id = tripID
        let predicate = #Predicate<Trip> { $0.id == id }
        guard let trip = try? modelContext.fetch(FetchDescriptor<Trip>(predicate: predicate)).first else {
            return nil
        }
        return Set((trip.stays ?? []).map(\.id))
    }

    /// Test-only: a trip's `classifiedByAI` from THIS actor's own (possibly
    /// unsaved) context. Returns nil if no trip with that id exists.
    func classifiedByAIForTesting(_ tripID: UUID) -> Bool? {
        let id = tripID
        let predicate = #Predicate<Trip> { $0.id == id }
        guard let trip = try? modelContext.fetch(FetchDescriptor<Trip>(predicate: predicate)).first else {
            return nil
        }
        return trip.classifiedByAI
    }

    /// Test seam returning a Sendable category from this actor's unsaved context; nil means absent.
    func stayCategoryForTesting(_ stayID: UUID) -> StayCategory? {
        let id = stayID
        let predicate = #Predicate<Stay> { $0.id == id }
        guard let stay = try? modelContext.fetch(FetchDescriptor<Stay>(predicate: predicate)).first else {
            return nil
        }
        return stay.category
    }
    #endif
}
