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
import os.log

extension TripClassifier {

    // MARK: - Stage 2.5: Sanity Checks

    /// Assembly requires destination stays to belong to trips and home/routine stays to remain tripless.
    /// Unassigned transit is legitimate residue; suppressed destinations that are not user-overridden
    /// are also valid while their fingerprints excuse them, including dwell growth below the known crossing time.
    /// Fetch errors return true to run the back half; internal for steady-state tests.
    /// `pinnedTripIDs` are the favourites as the pass reads them (nil skips
    /// the favourite comparison, for a caller that has none).
    func assemblyInvariantViolated(pinnedTripIDs: Set<UUID>? = nil) -> Bool {
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
        // With real homes only it still holds what no fingerprint does: which home
        // areas hold each destination and every tripless transit row whole.
        if !unassigned.isEmpty {
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
            let current = Self.suppressionInputDigest(
                rings: withShapes(anchors.map { Self.HomeRing($0) }, overrides: overrides),
                stays: tripless)
            if current != gateSuppressionInputDigest { return true }
        }

        let misattachedDescriptor = FetchDescriptor<Stay>(predicate: #Predicate {
            ($0.categoryRaw == "home" || $0.categoryRaw == "routine") && $0.trip != nil
        })
        guard let misattached = try? modelContext.fetchCount(misattachedDescriptor) else { return true }
        if misattached > 0 { return true }

        // A spared trip nothing the user chose holds any more is released by the back half.
        if let pinnedTripIDs {
            guard let decision = try? sparedTripReleases(pinnedTripIDs: pinnedTripIDs) else { return true }
            if !decision.release.isEmpty { return true }
        }

        // A home stay this device did not classify (one that synced in, or one
        // a Visit or more dwell made qualify) can split a completed trip, which
        // only assembly reconsiders: boundaries other than the last scan's run it.
        return retroactiveBoundariesMoved(pinnedTripIDs: pinnedTripIDs)
    }

    /// Whether the retroactive home boundaries, or the completed trips they
    /// may split, differ from what the last committed scan read. A trip the
    /// scan left whole because the user curated it is compared every time
    /// (a favourite has no store history): once it is no longer curated it
    /// is scanned again. Store history decides how much else to read: nothing
    /// when nothing committed since, only the stays and trips a commit
    /// touched when it touched no home stay or Visit and put no completed
    /// trip's member where the scan did not read one, and otherwise the home
    /// stays once, as a projection. A completed trip holding a member the
    /// scan did not read (one that synced in with its stays, or a stay that
    /// joined it) runs the back half when a retroactive boundary separates
    /// two of its stays. Boundaries found unchanged move the scan's token on,
    /// so the same commits are not read again. A failed read runs the back half.
    func retroactiveBoundariesMoved(pinnedTripIDs: Set<UUID>? = nil) -> Bool {
        // Nil only before this process's first assembly, which the launch latch runs.
        guard var scan = acknowledgedHistoricalScan else { return false }
        if let pinnedTripIDs, !scan.curatedSpanning.isEmpty {
            guard let curated = try? currentlyCuratedSpanning(scan, pinnedTripIDs: pinnedTripIDs),
                  curated == scan.curatedSpanning else { return true }
        }
        let window = storeHistory(after: scan.token)
        let joined: [Trip]
        if let window {
            if window.isEmpty { return false }
            guard let touchesHome = touchesHomeBoundaries(window, scan: scan),
                  let trips = tripsWithUnreadMembers(window, scan: scan) else { return true }
            joined = trips
            if !touchesHome, joined.isEmpty {
                scan.token = window.latest
                acknowledgedHistoricalScan = scan
                return false
            }
        } else {
            // Without history every membership is read, as assembly reads them.
            guard let trips = try? tripsWithUnreadMembers(scan: scan) else { return true }
            joined = trips
        }
        // Dated before the projection, so a commit during it is read next time.
        let token = window?.latest ?? newestStoreHistoryToken()
        var descriptor = FetchDescriptor<Stay>(predicate: #Predicate { $0.categoryRaw == "home" })
        descriptor.propertiesToFetch = [\.id, \.startTime, \.endTime, \.categoryRaw, \.sourceRaw, \.pingCount]
        guard let homes = try? modelContext.fetch(descriptor) else { return true }
        // The pass's Visit credit holds unless a Visit committed since the scan.
        let visitBacked: Set<UUID>
        if let window, window.rows(of: Visit.self) == nil {
            visitBacked = visitBackedStayIDs
        } else {
            guard let fresh = try? fetchVisitBackedStayIDs() else { return true }
            visitBacked = fresh
        }
        let retroactive = retroactiveHomeBoundaries(homes, visitBacked: visitBacked)
        guard Self.retroactiveBoundaryDigest(retroactive.spans, within: scan.extents) == scan.boundaries else {
            return true
        }
        if joined.contains(where: { spansHomeBoundary($0.orderedStays, boundaries: retroactive.index) }) {
            return true
        }
        scan.token = token
        scan.homeStays = Set(homes.filter {
            scan.extents.overlaps(start: $0.startTime, end: $0.endTime)
        }.map(\.persistentModelID))
        acknowledgedHistoricalScan = scan
        return false
    }

    /// The trips among the scan's curated spanning ones that assembly would
    /// still leave whole for the user (`historicalScanDue`'s comparison).
    private func currentlyCuratedSpanning(
        _ scan: HistoricalBoundaryScan, pinnedTripIDs: Set<UUID>
    ) throws -> Set<UUID> {
        let ids = Array(scan.curatedSpanning)
        let held = try modelContext.fetch(FetchDescriptor<Trip>(predicate: #Predicate {
            ids.contains($0.id) && $0.isComplete == true && $0.userEdited == false
        }))
        let kept = try fetchRequiredKeptTripIDs()
        return try curatedTrips(among: held.filter { !kept.contains($0.id) }, pinnedTripIDs: pinnedTripIDs)
    }

    /// The completed trips assembly's scan may take apart (`completedMembership`)
    /// that hold a member the scan did not read, among every stay.
    private func tripsWithUnreadMembers(scan: HistoricalBoundaryScan) throws -> [Trip] {
        let stays = try modelContext.fetch(FetchDescriptor<Stay>(predicate: #Predicate {
            $0.categoryRaw == "destination" || $0.categoryRaw == "transit"
        }))
        return tripsWithUnreadMembers(stays, scan: scan, keptTripIDs: try fetchRequiredKeptTripIDs())
    }

    /// The same, among the stays and trips the commits in `window` changed;
    /// a temporary home's change can release a kept trip, so it reads every
    /// stay. Nil when the changed rows cannot be read.
    private func tripsWithUnreadMembers(
        _ window: StoreHistoryWindow, scan: HistoricalBoundaryScan
    ) -> [Trip]? {
        let stayRows = window.rows(of: Stay.self)
        let tripRows = window.rows(of: Trip.self)
        if window.rows(of: TemporaryHome.self) != nil
            || stayRows?.overflowed == true || tripRows?.overflowed == true {
            return try? tripsWithUnreadMembers(scan: scan)
        }
        let changedStays = Set((stayRows?.inserted ?? []) + (stayRows?.updated ?? []))
        let changedTrips = Set((tripRows?.inserted ?? []) + (tripRows?.updated ?? []))
        guard !changedStays.isEmpty || !changedTrips.isEmpty else { return [] }
        do {
            var stays: [Stay] = []
            if !changedStays.isEmpty {
                stays += try modelContext.fetch(FetchDescriptor<Stay>(predicate: #Predicate {
                    changedStays.contains($0.persistentModelID)
                        && ($0.categoryRaw == "destination" || $0.categoryRaw == "transit")
                }))
            }
            if !changedTrips.isEmpty {
                for trip in try modelContext.fetch(FetchDescriptor<Trip>(predicate: #Predicate {
                    changedTrips.contains($0.persistentModelID)
                })) {
                    stays += (trip.stays ?? []).filter { $0.category == .destination || $0.category == .transit }
                }
            }
            return tripsWithUnreadMembers(stays, scan: scan, keptTripIDs: try fetchRequiredKeptTripIDs())
        } catch {
            return nil
        }
    }

    private func tripsWithUnreadMembers(
        _ stays: [Stay], scan: HistoricalBoundaryScan, keptTripIDs: Set<UUID>
    ) -> [Trip] {
        var trips: [ObjectIdentifier: Trip] = [:]
        for stay in stays where !stay.isDeleted {
            guard let trip = stay.trip, !trip.isDeleted, trip.isComplete, !trip.userEdited,
                  !keptTripIDs.contains(trip.id),
                  !scan.membership.contains(StayMembership(stayID: stay.id, tripID: trip.id)) else { continue }
            trips[ObjectIdentifier(trip)] = trip
        }
        return Array(trips.values)
    }

    /// Whether the commits in `window` may have moved a home boundary within
    /// the scan's completed trips: a Visit changed, a home stay there changed
    /// or went, or a changed stay is a home stay there now. A home stay that
    /// grows after the last trip moves none. Nil when the changed stays cannot
    /// be read.
    private func touchesHomeBoundaries(
        _ window: StoreHistoryWindow, scan: HistoricalBoundaryScan
    ) -> Bool? {
        if window.rows(of: Visit.self) != nil { return true }
        guard let stays = window.rows(of: Stay.self) else { return false }
        if stays.overflowed { return true }
        let changed = stays.inserted + stays.updated
        if (changed + stays.deleted).contains(where: scan.homeStays.contains) { return true }
        guard !changed.isEmpty else { return false }
        let ids = Set(changed)
        var nowHome = FetchDescriptor<Stay>(predicate: #Predicate {
            ids.contains($0.persistentModelID) && $0.categoryRaw == "home"
        })
        nowHome.propertiesToFetch = [\.startTime, \.endTime]
        guard let homes = try? modelContext.fetch(nowHome) else { return nil }
        return homes.contains { scan.extents.overlaps(start: $0.startTime, end: $0.endTime) }
    }

    /// Clustering can change sanity inputs without unclassifying stays. These predicates MUST mirror
    /// sanityCheckClassifications, including user-override exemptions; fetch errors run the back half.
    func sanityFixpointViolated() -> Bool {
        let fiveDaysInMinutes = 5 * 24 * 60
        let twentyFourHoursInMinutes = 24 * 60
        let shortStopMinutes = StayClassificationInputs.shortStopMinutes
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
            $0.categoryRaw == "destination" && $0.durationMinutes <= shortStopMinutes
                && $0.userOverridden == false
        })
        guard let blip = try? modelContext.fetch(blipDestination) else { return true }
        let violating = long + airport + blip
        guard !violating.isEmpty else { return false }

        // The sanity pass changes a copy only when its logical stay's deciding copy
        // violates, so judge each violating UUID among the same copies it groups.
        let ids = Set(violating.map(\.id))
        guard let copies = try? modelContext.fetch(FetchDescriptor<Stay>(
            predicate: #Predicate { ids.contains($0.id) })),
              let corrections = try? sanityCorrections(among: copies.filter(Self.isSanityCandidate))
        else { return true }
        return !corrections.isEmpty
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
        let boundaries = HomeBoundaryIndex(qualifyingHomeBoundarySpans(homes))
        guard !boundaries.isEmpty else { return false }
        return openTrips.contains { trip in
            guard let last = trip.orderedStays.last else { return false }
            return boundaries.hasStart(atOrAfter: last.endTime)
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
    /// Test seam for routine reconciliation without the pipeline latch.
    func applyRoutinePlaceChangeCoreForTesting(placeID: UUID) -> CoverageReconciliationOutcome {
        applyRoutinePlaceChangeCore(placeID: placeID)
    }

    func assemblyInvariantViolatedForTesting(pinnedTripIDs: Set<UUID>? = nil) -> Bool {
        assemblyInvariantViolated(pinnedTripIDs: pinnedTripIDs)
    }

    /// Test seam for sanity-threshold parity and convergence after one corrective pass.
    func sanityFixpointViolatedForTesting() -> Bool { sanityFixpointViolated() }
    #endif

    /// Fix obvious classification errors with the same evidence rules Stage 2a
    /// settles by (`StayEvidence.sanityCorrection`), so the two cannot
    /// oscillate. User-overridden stays are never modified (the
    /// predicate filters them out). Only the category changes —
    /// `continuesPreviousTrip` is left alone because trip boundaries are about
    /// whether the user went home, not what happened at a particular stop.
    /// Same-UUID copies are one logical stay: its deciding copy is judged, and
    /// its correction reaches every copy still in the category it corrects.
    /// A corrected stay's owning trip gets its summary recomputed and its
    /// `aiGeneratedTitle` cleared (Stage 5 regenerates). Returns the number
    /// of stays corrected, or -1 when a read fails (nothing is mutated
    /// before it).
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
        let corrections: [UUID: (from: StayCategory, to: StayCategory)]
        do {
            corrections = try sanityCorrections(among: stays)
        } catch {
            logger.error("Sanity check skipped; evidence unreadable: \(error.localizedDescription)")
            return -1
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
        // input has changed even if its text might happen to stay the same.
        if !affectedTrips.isEmpty {
            for trip in affectedTrips.values where !trip.isDeleted {
                TripTitleStore.invalidateGeneratedTitles(
                    for: trip, in: modelContext)
                recomputeBackHalfSummary(trip)
            }
            logger.info("Recomputed summaries (+ cleared AI titles) for \(affectedTrips.count) trip(s) affected by sanity checks.")
        }

        return corrected
    }

    /// A stay the sanity pass reads: classified destination or transit, not user-overridden.
    private static func isSanityCandidate(_ stay: Stay) -> Bool {
        (stay.category == .destination || stay.category == .transit) && !stay.userOverridden
    }

    /// Each logical stay's correction, judged by its deciding copy. Evidence
    /// is read only for a deciding copy whose stored duration could violate
    /// (`StayEvidence` never judges a stay shorter or longer than that).
    /// A failed read throws.
    private func sanityCorrections(among stays: [Stay]) throws
        -> [UUID: (from: StayCategory, to: StayCategory)] {
        let candidates = Self.logicalClassificationRepresentatives(stays).values.filter { stay in
            switch stay.category {
            case .transit: return stay.durationMinutes >= 5 * 24 * 60
            case .destination:
                return stay.durationMinutes <= StayClassificationInputs.shortStopMinutes
                    || (stay.isAirport && stay.durationMinutes < 24 * 60)
            default: return false
            }
        }
        guard !candidates.isEmpty else { return [:] }
        let evidence = try stayEvidence(for: Array(candidates), timeline: nil)
        var corrections: [UUID: (from: StayCategory, to: StayCategory)] = [:]
        for stay in candidates {
            if let to = evidence[ObjectIdentifier(stay)]?.sanityCorrection(of: stay.category) {
                corrections[stay.id] = (stay.category, to)
            }
        }
        return corrections
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
        return (try? classifyWithHeuristics(stays: stays)) ?? -1
    }

    /// Test seam mirroring the resolution, heuristic, and sanity sequence in one context so neighbour decisions remain visible.
    func runDeterministicClassificationForTesting() -> (resolved: Int, heuristic: Int, corrected: Int) {
        let raw = StayCategory.unclassified.rawValue
        let descriptor = FetchDescriptor<Stay>(
            predicate: #Predicate { $0.categoryRaw == raw },
            sortBy: [SortDescriptor(\.startTime, order: .forward)]
        )
        let stays = (try? modelContext.fetch(descriptor)) ?? []
        guard let timeline = try? orderedClassificationStays(in: modelContext),
              let settled = try? resolveDeterministicOutcomes(stays, timeline: timeline),
              let heuristic = try? classifyWithHeuristics(stays: settled.ambiguous, ordered: timeline) else {
            return (-1, -1, -1)
        }
        let corrected = sanityCheckClassifications()
        return (settled.resolved.count, heuristic, corrected)
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
