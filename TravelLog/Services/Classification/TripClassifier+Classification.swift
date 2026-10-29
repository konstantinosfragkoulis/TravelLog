//
//  TripClassifier+Classification.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import Foundation
import SwiftData
import CoreLocation
import os.log

extension TripClassifier {

    // MARK: - Stage 1: Pre-filtering

    /// Pre-filter through shared home and routine predicates, including their prehistory fallbacks.
    /// A home stamp records its `temporaryOwner` and that owner's coverage revision with the category.
    /// Returns -1 when a dependency read fails; nothing is mutated before those reads.
    /// `candidates` limits the pass to those stays; nil covers every unclassified stay.
    internal func preFilterStays(_ candidates: [Stay]? = nil) -> Int {
        stampedAnchors = []
        // Include ended homes and routine places for historical stays.
        guard let dependencies = fetchHomeAreaDependencies(orSkip: "Pre-filter") else { return -1 }
        let allHomes = classificationAnchors(of: dependencies)
        let allRoutinePlaces = dependencies.routinePlaces
        let overrides = dependencies.overrides

        let routineRings = allRoutinePlaces.map {
            RoutineRing(
                latitude: $0.latitude,
                longitude: $0.longitude,
                radiusMeters: $0.radiusMeters,
                startedAt: $0.startedAt,
                endedAt: $0.endedAt
            )
        }

        let predicate = #Predicate<Stay> { $0.categoryRaw == "unclassified" }
        let descriptor = FetchDescriptor<Stay>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.startTime, order: .forward)]
        )

        // A failed read is not an empty backlog: missed home/routine stamps
        // would fall through to the heuristic destination default.
        // The test hook fails the pre-filter's stay input either way: an
        // uncapped pass hands its unit's rows in from its own read.
        #if DEBUG
        if failPreFilterStayFetchForTesting {
            logger.error("Pre-filter skipped; stays unreadable (test).")
            return -1
        }
        #endif
        let unclassified: [Stay]
        if let candidates {
            unclassified = candidates.filter { $0.category == .unclassified }
        } else {
            do {
                unclassified = try modelContext.fetch(descriptor)
            } catch {
                logger.error("Pre-filter skipped; stays unreadable: \(error.localizedDescription)")
                return -1
            }
        }
        guard !unclassified.isEmpty else { return 0 }

        var count = 0
        let homeRings = withShapes(allHomes.map { Self.HomeRing($0) }, overrides: overrides)
        let hasTemporaryRing = homeRings.contains(where: \.isTemporary)

        for stay in unclassified {
            let coordinate = CLLocationCoordinate2D(
                latitude: stay.centroidLatitude,
                longitude: stay.centroidLongitude
            )

            // Home passes 1+2 live in the shared `matchesHome` — the SAME
            // rule `applyHomeChangeCore`'s stale-home pass uses to UNstamp,
            // so stamping and unstamping can never disagree (a divergent
            // pair would oscillate on every reconciliation).
            if Self.matchesHome(
                stayStart: stay.startTime,
                latitude: stay.centroidLatitude,
                longitude: stay.centroidLongitude,
                homes: homeRings
            ) {
                stay.category = .home
                stampedAnchors.append(stay)
                // Who made it home, in the same mutation as the category, so
                // the two commit or roll back together. Without a temporary
                // ring this is nil, and nil over nil writes nothing.
                // The revision is the owner's collapsed copy's.
                let owner = hasTemporaryRing
                    ? Self.temporaryOwner(
                        stayStart: stay.startTime, latitude: stay.centroidLatitude,
                        longitude: stay.centroidLongitude, rings: homeRings)
                    : nil
                stay.setTemporaryHomeProvenance(
                    owner, revision: owner.flatMap { dependencies.temporaryHomeRevisions[$0] })
                count += 1
            }

            // Use the same matchesRoutine predicate as applyRoutinePlaceChangeCore to prevent oscillation.
            if stay.category == .unclassified {
                if Self.matchesRoutine(
                    stayStart: stay.startTime,
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    places: routineRings
                ) {
                    stay.category = .routine
                    stampedAnchors.append(stay)
                    count += 1
                }
            }
        }

        return count
    }


    // MARK: - Routine-place predicate

    nonisolated struct RoutineRing: Sendable {
        let latitude: Double
        let longitude: Double
        let radiusMeters: Double
        let startedAt: Date
        let endedAt: Date?

        func contains(latitude lat: Double, longitude lon: Double) -> Bool {
            CLLocation(latitude: latitude, longitude: longitude)
                .distance(from: CLLocation(latitude: lat, longitude: lon)) <= radiusMeters
        }
    }

    /// Shared predicate for preFilterStays and applyRoutinePlaceChangeCore so stamping and unstamping agree.
    /// Use inclusive active windows; prehistory deliberately matches only current places, unlike matchesHome.
    nonisolated static func matchesRoutine(
        stayStart: Date,
        latitude: Double,
        longitude: Double,
        places: [RoutineRing]
    ) -> Bool {
        // Pass 1: strict time-window match.
        for place in places {
            if let endedAt = place.endedAt, stayStart > endedAt { continue }
            if place.startedAt > stayStart { continue }
            if place.contains(latitude: latitude, longitude: longitude) { return true }
        }

        // Pass 2: current-place fallback for stays predating every record.
        let current = places.filter { $0.endedAt == nil }
        guard !current.isEmpty else { return false }
        guard places.allSatisfy({ stayStart < $0.startedAt }) else { return false }
        return current.contains { $0.contains(latitude: latitude, longitude: longitude) }
    }

    // MARK: - Stage 1.5: Reclassification Prep

    /// Stage 1.5. Every pass hands back the journey tail of each new anchor
    /// (`newAnchors`, the home and routine stays its Stage 1 stamped;
    /// `journeyTail(before:)`): a stop judged before its next anchor existed.
    /// With `recentWindow` (live passes, not imports or backlog bites) it also
    /// reconsiders the latest five journey stays longer than a blip when new
    /// journey context arrives; older stays remain settled context.
    /// Preserve completed trips before homecoming and user overrides. Return reset IDs for guaranteed Stage 2 inclusion,
    /// so the oldest-first backlog cap cannot strand them unclassified. Internal for seeded-store tests.
    /// Throws when the latest home stay or a tail cannot be read, before any change: a failed read is not
    /// "no home", which would make all history the current journey. Only a read that finds no
    /// home stay starts the journey at `distantPast`.
    internal func prepareForReclassification(newAnchors: [Stay] = [], recentWindow: Bool = true) throws -> [UUID] {
        let tail = try journeyTail(before: newAnchors)
        var window: [Stay] = []
        if recentWindow {
            // Find the most recent home stay - everything after it is the "current journey"
            let homePredicate = #Predicate<Stay> { $0.categoryRaw == "home" }
            var homeDescriptor = FetchDescriptor<Stay>(
                predicate: homePredicate,
                sortBy: [SortDescriptor(\.startTime, order: .reverse)]
            )
            homeDescriptor.fetchLimit = 1
            #if DEBUG
            if failReclassificationHomeReadForTesting { throw CocoaError(.fileReadUnknown) }
            #endif
            let lastHomeStay = try modelContext.fetch(homeDescriptor).first
            window = try recentJourneyWindow(since: lastHomeStay?.endTime ?? .distantPast)
        }

        var seen = Set<PersistentIdentifier>()
        let staysToReclassify = (window + tail).filter { seen.insert($0.persistentModelID).inserted }
        guard !staysToReclassify.isEmpty else { return [] }
        for stay in staysToReclassify {
            stay.category = .unclassified
        }

        logger.info("Reset \(staysToReclassify.count) recent stay(s) for reclassification.")
        return staysToReclassify.map(\.id)
    }

    /// The newest five journey stays Stage 1.5 hands back, unchanged.
    private func recentJourneyWindow(since journeyStart: Date) throws -> [Stay] {
        // Require new data in this journey; historical backlog must not repeatedly reset settled recent stays.
        let journeyUnclassifiedPredicate = #Predicate<Stay> {
            $0.categoryRaw == "unclassified" && $0.startTime >= journeyStart
        }
        let journeyUnclassifiedDescriptor = FetchDescriptor<Stay>(predicate: journeyUnclassifiedPredicate)
        guard let unclassifiedCount = try? modelContext.fetchCount(journeyUnclassifiedDescriptor),
              unclassifiedCount > 0 else {
            return [] // No new journey data - nothing to reclassify
        }

        // Fetch the 5 MOST RECENT non-user-overridden destination/transit stays
        // in the current journey. Only these are reclassified - older stays are
        // "settled" and won't flip-flop on repeated runs. Blips (at most
        // `shortStopMinutes`) do not count: a ferry's fixes after a port stay
        // must not push it out of the window before its next anchor arrives.
        let shortStopMinutes = StayClassificationInputs.shortStopMinutes
        let tripPredicate = #Predicate<Stay> {
            ($0.categoryRaw == "destination" || $0.categoryRaw == "transit") &&
            $0.userOverridden == false &&
            $0.durationMinutes > shortStopMinutes &&
            $0.startTime >= journeyStart
        }
        var tripDescriptor = FetchDescriptor<Stay>(
            predicate: tripPredicate,
            sortBy: [SortDescriptor(\.startTime, order: .reverse)]
        )
        tripDescriptor.fetchLimit = 5

        guard let fetched = try? modelContext.fetch(tripDescriptor),
              !fetched.isEmpty else {
            return []
        }

        // Preserve user-edited trip members as reclassifyAll and applyHomeChangeCore do.
        // Filter the relationship in memory after the newest-five window: skip protected rows without substituting older ones.
        return fetched.filter { !($0.trip?.userEdited ?? false) }
    }

    /// How many new anchors of one pass hand back their journey tails: a
    /// live pass stamps one or two; a backlog must not walk them all.
    nonisolated static let journeyTailAnchorCap = 5

    /// The stays a new anchor completes, which were judged before it existed:
    /// walking back from each of the newest `journeyTailAnchorCap` anchors,
    /// the automatic destination and transit stays up to and including the
    /// first that cannot be a blip (its stop before the anchor), within
    /// `anchorWalkLimit` stays, stopping at a home or routine stay. A stay
    /// the user set, or one in a trip the user edited or that is complete,
    /// keeps its category. A failed read throws.
    func journeyTail(before anchors: [Stay]) throws -> [Stay] {
        let newest = anchors.filter { !$0.isDeleted && ($0.category == .home || $0.category == .routine) }
            .sorted { $0.startTime > $1.startTime }
            .prefix(Self.journeyTailAnchorCap)
        var tail: [Stay] = []
        for anchor in newest {
            tail += try journeyTailRows(before: anchor).filter {
                ($0.category == .destination || $0.category == .transit) && !$0.userOverridden
                    && !($0.trip?.userEdited ?? false) && !($0.trip?.isComplete ?? false)
            }
        }
        return tail
    }

    /// The stays before `anchor` back to and including the first that
    /// cannot be a blip (longer than `shortStopMinutes`), within
    /// `anchorWalkLimit` stays and stopping at a home or routine stay: the
    /// stays whose next anchor `anchor` is. One bounded read; a failure throws.
    func journeyTailRows(before anchor: Stay) throws -> [Stay] {
        let start = anchor.startTime
        var descriptor = FetchDescriptor<Stay>(
            predicate: #Predicate { $0.startTime < start },
            sortBy: [SortDescriptor(\.startTime, order: .reverse)])
        descriptor.fetchLimit = Self.anchorWalkLimit
        var rows: [Stay] = []
        for stay in try modelContext.fetch(descriptor) where !stay.isDeleted {
            if stay.category == .home || stay.category == .routine { break }
            rows.append(stay)
            if stay.durationMinutes > StayClassificationInputs.shortStopMinutes { break }
        }
        return rows
    }

    // MARK: - Stage 2: Classification

    /// Heal summaries of user-edited trips after member reclassification because assembly never rebuilds them.
    /// A completed one is included: a rebuild target renamed since the reset keeps its members, which settle later.
    /// A failed read throws: the unit must not commit members without their summary.
    func healUserEditedOpenTripSummaries() throws {
        let changed = classifiedStayIDs
        guard !changed.isEmpty else { return }
        let predicate = #Predicate<Trip> { $0.userEdited == true }
        let trips = try modelContext.fetch(FetchDescriptor<Trip>(predicate: predicate))
        for trip in trips where (trip.stays ?? []).contains(where: { changed.contains($0.id) }) {
            TripTitleStore.invalidateGeneratedTitles(
                for: trip, in: modelContext)
            recomputeBackHalfSummary(trip)
        }
    }

    /// Back-half summary writers commit under the launch latch, so a summary
    /// built without its home-place filter is a required-read failure there
    /// (checked before the unit's save). Direct test calls simply ignore it.
    func recomputeBackHalfSummary(_ trip: Trip) {
        if !trip.recomputeSummary() { summaryHomePlacesUnreadable = true }
    }

    /// Merge the capped oldest-first backlog with guaranteed Stage 1.5 resets and bounded current-journey rows.
    /// Reset rows must classify this pass; journey priority prevents cancellation from stranding them behind imports.
    /// Journey priority requires a home anchor to avoid treating all history as the current journey.
    /// Deduplicate physical rows and sort chronologically; internal for guaranteed-inclusion tests.
    /// Every unclassified copy of an admitted UUID joins, so one decision covers the logical stay.
    /// Every source is a required read: a failure throws instead of shrinking the batch.
    internal func fetchStage2Batch(cap: Int?, priorityIDs: [UUID]) throws -> [Stay] {
        #if DEBUG
        if failStage2BatchFetchForTesting { throw CocoaError(.fileReadUnknown) }
        #endif
        let predicate = #Predicate<Stay> { $0.categoryRaw == "unclassified" }
        var descriptor = FetchDescriptor<Stay>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.startTime, order: .forward)]
        )
        if let cap {
            descriptor.fetchLimit = cap
        }
        var batch = try modelContext.fetch(descriptor)
        var seen = Set(batch.map(\.id))
        var seenRows = Set(batch.map(\.persistentModelID))

        // Source 3: journey-priority rows. Only meaningful (and only
        // bounded) when a home stay anchors the journey window.
        if cap != nil {
            let homePredicate = #Predicate<Stay> { $0.categoryRaw == "home" }
            var homeDescriptor = FetchDescriptor<Stay>(
                predicate: homePredicate,
                sortBy: [SortDescriptor(\.startTime, order: .reverse)]
            )
            homeDescriptor.fetchLimit = 1
            let latestHome = try modelContext.fetch(homeDescriptor).first
            // The stop before the latest home, which a Stage 1.5 reset left
            // unclassified if its pass was cancelled before Stage 2: it is
            // behind the journey, so the oldest-first cap could strand it.
            if let latestHome {
                for stay in try journeyTailRows(before: latestHome)
                where stay.category == .unclassified && seenRows.insert(stay.persistentModelID).inserted {
                    batch.append(stay)
                    seen.insert(stay.id)
                }
            }
            if let journeyStart = latestHome?.endTime {
                let journeyPredicate = #Predicate<Stay> {
                    $0.categoryRaw == "unclassified" && $0.startTime >= journeyStart
                }
                var journeyDescriptor = FetchDescriptor<Stay>(
                    predicate: journeyPredicate,
                    sortBy: [SortDescriptor(\.startTime, order: .forward)]
                )
                journeyDescriptor.fetchLimit = Self.stage2JourneyPriorityCap
                for stay in try modelContext.fetch(journeyDescriptor)
                where seenRows.insert(stay.persistentModelID).inserted {
                    batch.append(stay)
                    seen.insert(stay.id)
                }
            }
        }

        // Source 2: hard-guaranteed rows (Stage 1.5's resets).
        let missing = priorityIDs.filter { !seen.contains($0) }
        if !missing.isEmpty {
            let missingPredicate = #Predicate<Stay> {
                missing.contains($0.id) && $0.categoryRaw == "unclassified"
            }
            for stay in try modelContext.fetch(FetchDescriptor<Stay>(predicate: missingPredicate))
            where seenRows.insert(stay.persistentModelID).inserted {
                batch.append(stay)
                seen.insert(stay.id)
            }
        }

        // A cap can cut between UUID twins; admit the remaining copies.
        if cap != nil, !batch.isEmpty {
            #if DEBUG
            if failStage2CohortFetchForTesting { throw CocoaError(.fileReadUnknown) }
            #endif
            let admitted = Array(seen)
            let twinPredicate = #Predicate<Stay> {
                admitted.contains($0.id) && $0.categoryRaw == "unclassified"
            }
            for stay in try modelContext.fetch(FetchDescriptor<Stay>(predicate: twinPredicate))
            where seenRows.insert(stay.persistentModelID).inserted {
                batch.append(stay)
            }
        }

        // Equal start times keep one order, so plans number them alike on every pass.
        batch.sort(by: Self.classificationOrder)
        return batch
    }

    /// Bound on Stage 2's journey-priority lane (`fetchStage2Batch` source
    /// 3): big enough to cover any live journey's pending stays in one
    /// pass, small enough that the per-call freeze cap keeps its meaning
    /// even when an import lands mid-trip.
    nonisolated static let stage2JourneyPriorityCap = 40

    // MARK: - Stage 2a: Deterministic Outcome Resolution

    /// Settle the stays whose evidence alone decides (`StayEvidence.settledCategory`,
    /// which the sanity pass also reads, so the two cannot oscillate); the rest
    /// are left for the heuristics. A UUID's eligible copies are resolved or left
    /// ambiguous together, by the copy the heuristics decide from. `timeline`
    /// (classification order) gives a photo stay its next observation; nil reads
    /// it from the store. A failed read throws before any change.
    internal func resolveDeterministicOutcomes(
        _ stays: [Stay], timeline: [Stay]?
    ) throws -> (resolved: [Stay], ambiguous: [Stay]) {
        let eligible = stays.filter { $0.category == .unclassified && !$0.userOverridden }
        let representatives = Self.logicalClassificationRepresentatives(eligible)
        let evidence = try stayEvidence(for: Array(representatives.values), timeline: timeline)
        let decided = representatives.compactMapValues { evidence[ObjectIdentifier($0)]?.settledCategory }
        var resolved: [Stay] = []
        var ambiguous: [Stay] = []

        for stay in eligible {
            guard let category = decided[stay.id] else {
                ambiguous.append(stay)
                continue
            }
            stay.category = category
            classifiedStayIDs.insert(stay.id)
            resolved.append(stay)
        }

        return (resolved, ambiguous)
    }

    // MARK: - Heuristics

    /// Rule-based classification for every stay the duration rules leave
    /// open: an airport stop is transit, so is a journey stop
    /// (`isJourneyStop`), and anything else is a destination (when uncertain,
    /// prefer destination: the user can reclassify). Every duration the rules
    /// test is read through `StayEvidence`: a photo stay is brief only on what
    /// its photos show, a base only on what its photos show, and a night is
    /// possible until the next observation shows otherwise.
    /// `suppliedTimeline` is the full classification-ordered timeline; nil
    /// reads it. A failed read throws before any change.
    ///
    /// Calendar events are deliberately not consulted: an occasion could
    /// only corroborate a destination, which is already the default, and
    /// must never override a transit rule.
    func classifyWithHeuristics(stays: [Stay], ordered suppliedTimeline: [Stay]? = nil,
                                in context: ModelContext? = nil) throws -> Int {
        let context = context ?? modelContext
        var classified = 0

        // Use true chronological neighbours.
        // UUID twins are one logical stay: decided once with real neighbours, copied to every eligible copy.
        let eligible = stays.filter { $0.category == .unclassified && !$0.userOverridden }
        guard !eligible.isEmpty else { return 0 }
        let copies = Dictionary(grouping: eligible, by: \.id)
        let timeline = try suppliedTimeline ?? orderedClassificationStays(in: context)
        let ordered = Self.logicalClassificationTimeline(timeline, batch: eligible)
        var indexByID: [UUID: Int] = [:]
        for (idx, s) in ordered.enumerated() { indexByID[s.id] = idx }
        let batch = Self.logicalClassificationBatch(eligible)
        // Evidence for each decided stay and every stay its anchor walks can
        // read, in one read: each walk passes only stays short enough to be a
        // blip, so it covers them up to the first that cannot be one.
        var needed: [ObjectIdentifier: Stay] = [:]
        for stay in batch {
            needed[ObjectIdentifier(stay)] = stay
            guard let idx = indexByID[stay.id] else { continue }
            for step in [-1, 1] {
                var i = idx + step
                var walked = 0
                while ordered.indices.contains(i), walked < Self.anchorWalkLimit {
                    let candidate = ordered[i]
                    needed[ObjectIdentifier(candidate)] = candidate
                    if candidate.category == .home || candidate.category == .routine
                        || candidate.durationMinutes > StayClassificationInputs.shortStopMinutes { break }
                    i += step
                    walked += 1
                }
            }
        }
        let evidence = try stayEvidence(for: Array(needed.values), timeline: timeline, in: context)
        func judged(_ stay: Stay) -> StayEvidence {
            evidence[ObjectIdentifier(stay)] ?? StayEvidence(measured: stay)
        }
        /// The nearest stay from `index` in direction `step` that is not a
        /// blip: home or routine, or no short stop. Nil past the timeline's
        /// end or the walk limit.
        func anchor(from index: Int, step: Int) -> Stay? {
            var i = index + step
            var walked = 0
            while ordered.indices.contains(i), walked < Self.anchorWalkLimit {
                let candidate = ordered[i]
                if candidate.category == .home || candidate.category == .routine
                    || !judged(candidate).isShortStop { return candidate }
                i += step
                walked += 1
            }
            return nil
        }

        for stay in batch {
            let category: StayCategory
            let facts = judged(stay)

            if facts.isAirportStop {
                // Airport transit takes precedence over the journey test; stays
                // of 24 hours or more, or with a night, may be airport hotels.
                category = .transit
            } else if let idx = indexByID[stay.id],
                      let before = anchor(from: idx, step: -1), let after = anchor(from: idx, step: 1),
                      isJourneyStop(stay, facts: facts, before: before, after: after, evidence: judged) {
                category = .transit
            } else {
                category = .destination
            }

            for copy in copies[stay.id] ?? [] {
                copy.category = category
                classifiedStayIDs.insert(copy.id)
                classified += 1
            }
        }

        return classified
    }

    /// How many stays an anchor walk passes before it gives up: a years-long
    /// run of blips must not make classification quadratic.
    nonisolated static let anchorWalkLimit = 60

    /// Whether the journey test reads a stay that is no home or routine
    /// stay as a base, on its evidence: observably six hours or longer and
    /// not itself a stop. Import reads it too, to hand back the stops beside
    /// a stay its photos make one.
    nonisolated static func readsAsBase(_ evidence: StayEvidence) -> Bool {
        !evidence.isAirportStop && !evidence.isShortStop && evidence.lasted(atLeast: 360)
    }

    /// A pause between the legs of a journey: a ferry-port wait, a rest stop
    /// on a drive, a port call, a change of trains. `before` and `after` are
    /// its anchors, the nearest stays on each side that are not blips (the
    /// fixes of a moving phone), so they are where the legs around it start
    /// and end. No stay where the user may have slept is one.
    ///
    /// - Through-stop: a brief stop with both anchors elsewhere (at least
    ///   8 km away, so nothing else of the trip happened here right before or
    ///   after; a home or routine anchor needs only 1 km, since the stay is
    ///   outside that area, though never at the anchor's own place), at least
    ///   one leg of 30 km, and on the way between them (the legs at most 1.5
    ///   times the direct distance).
    /// - Departure or arrival: a stop under 90 minutes within 25 km of a base
    ///   on one side (home, routine, or a stay observably six hours or longer
    ///   that is not itself a stop) with the other anchor 30 km or more away:
    ///   the base's station, port or airport.
    ///
    /// Distances are great-circle km between centroids.
    private func isJourneyStop(_ stay: Stay, facts: StayEvidence, before: Stay, after: Stay,
                               evidence: (Stay) -> StayEvidence) -> Bool {
        guard !facts.nightPossible else { return false }
        func km(_ a: Stay, _ b: Stay) -> Double {
            HomeOrbit.greatCircleKm(a.centroidLatitude, a.centroidLongitude, b.centroidLatitude, b.centroidLongitude)
        }
        func isHome(_ s: Stay) -> Bool { s.category == .home || s.category == .routine }
        let toBefore = km(stay, before)
        let toAfter = km(stay, after)

        func isElsewhere(_ anchor: Stay, at distance: Double) -> Bool {
            distance >= 8 || (isHome(anchor) && distance >= 1)
        }
        if facts.isBrief,
           isElsewhere(before, at: toBefore), isElsewhere(after, at: toAfter),
           max(toBefore, toAfter) >= 30,
           (toBefore + toAfter) / max(km(before, after), 1) <= 1.5 {
            return true
        }

        guard facts.isShorter(than: 90) else { return false }
        func isBase(_ anchor: Stay, at distance: Double) -> Bool {
            guard distance <= 25 else { return false }
            return isHome(anchor) || Self.readsAsBase(evidence(anchor))
        }
        return (isBase(before, at: toBefore) && toAfter >= 30) || (isBase(after, at: toAfter) && toBefore >= 30)
    }
}
