//
//  TripClassifier+Classification.swift
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

    // MARK: - Stage 1: Pre-filtering

    /// Pre-filter through shared home and routine predicates, including their prehistory fallbacks.
    /// A home stamp records its `temporaryOwner` and that owner's coverage revision with the category.
    /// Returns -1 when a dependency read fails; nothing is mutated before those reads.
    /// `candidates` limits the pass to those stays; nil covers every unclassified stay.
    internal func preFilterStays(_ candidates: [Stay]? = nil) -> Int {
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
        let unclassified: [Stay]
        if let candidates {
            unclassified = candidates.filter { $0.category == .unclassified }
        } else {
            do {
                #if DEBUG
                if failPreFilterStayFetchForTesting { throw CocoaError(.fileReadUnknown) }
                #endif
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

    /// Reconsider only the latest five journey stays when new journey context arrives; older stays remain settled context.
    /// Preserve completed trips before homecoming and user overrides. Return reset IDs for guaranteed Stage 2 inclusion,
    /// so the oldest-first backlog cap cannot strand them unclassified. Internal for seeded-store tests.
    /// Throws when the latest home stay cannot be read, before any change: a failed read is not
    /// "no home", which would make all history the current journey. Only a read that finds no
    /// home stay starts the journey at `distantPast`.
    internal func prepareForReclassification() throws -> [UUID] {
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
        let journeyStart = lastHomeStay?.endTime ?? .distantPast

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
        // "settled" and won't flip-flop on repeated runs.
        let tripPredicate = #Predicate<Stay> {
            ($0.categoryRaw == "destination" || $0.categoryRaw == "transit") &&
            $0.userOverridden == false &&
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
        let staysToReclassify = fetched.filter { !($0.trip?.userEdited ?? false) }
        guard !staysToReclassify.isEmpty else { return [] }

        for stay in staysToReclassify {
            stay.category = .unclassified
        }

        logger.info("Reset \(staysToReclassify.count) recent stay(s) for reclassification.")
        return staysToReclassify.map(\.id)
    }

    // MARK: - Stage 2: AI Classification

    /// Heal summaries of user-edited trips after member reclassification because assembly never rebuilds them.
    /// A completed one is included: a rebuild target renamed during inference keeps its members, which settle later.
    /// A failed read throws: the unit must not commit members without their summary.
    func healUserEditedOpenTripSummaries(alsoChanged extra: Set<UUID> = []) throws {
        let changed = fmClassifiedStayIDs.union(heuristicClassifiedStayIDs).union(extra)
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
    /// Every unclassified copy of an admitted UUID joins, so one plan decides the logical stay.
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
            if let journeyStart = try modelContext.fetch(homeDescriptor).first?.endTime {
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

    /// Resolve model-independent categories before inference; thresholds MUST mirror sanityCheckClassifications
    /// exactly to prevent oscillation. Resolved stays remain settled context in the prompt.
    /// A UUID's eligible copies are resolved or left ambiguous together, by the copy the
    /// model and heuristic lanes decide from.
    /// Register provenance only after the Stage 2 lane outcome is known; internal for deterministic tests.
    internal func resolveDeterministicOutcomes(
        _ stays: [Stay]
    ) -> (resolved: [Stay], ambiguous: [Stay]) {
        let eligible = stays.filter { $0.category == .unclassified && !$0.userOverridden }
        let decided = Self.logicalClassificationRepresentatives(eligible)
            .compactMapValues(Self.deterministicCategory(for:))
        var resolved: [Stay] = []
        var ambiguous: [Stay] = []

        for stay in eligible {
            guard let category = decided[stay.id] else {
                ambiguous.append(stay)
                continue
            }
            stay.category = category
            resolved.append(stay)
        }

        return (resolved, ambiguous)
    }

    /// The category a stay's duration alone settles, or nil when only context can decide.
    private static func deterministicCategory(for stay: Stay) -> StayCategory? {
        if stay.durationMinutes >= 5 * 24 * 60 { return .destination }
        if (stay.isAirport && stay.durationMinutes < 24 * 60) || stay.durationMinutes <= 20 {
            return .transit
        }
        return nil
    }

    /// Credit deterministic outcomes to the applicable engine so FM-capable all-deterministic trips
    /// do not remain permanently in the Enhance History backlog.
    internal func registerStage2aProvenance(_ stays: [Stay], asFM: Bool) {
        for stay in stays {
            if asFM {
                fmClassifiedStayIDs.insert(stay.id)
            } else {
                heuristicClassifiedStayIDs.insert(stay.id)
            }
        }
    }

    /// FM availability alone grants credit only for all-deterministic work;
    /// when ambiguous stays exist, the FM lane must actually produce output.
    nonisolated static func stage2aCreditsAsFM(
        fmAvailable: Bool,
        hadAmbiguousStays: Bool,
        fmLaneProducedOutput: Bool
    ) -> Bool {
        guard fmAvailable else { return false }
        return !hadAmbiguousStays || fmLaneProducedOutput
    }

    /// The decode grammar constrains categories but cannot guarantee index coverage.
    /// Count repeated out-of-range indices only as outOfRange, matching applyClassificationInput deduplication.
    nonisolated static func validateClassificationIndices(
        count: Int, indices: [Int]
    ) -> (missing: Set<Int>, duplicates: Set<Int>, outOfRange: Set<Int>) {
        var seen = Set<Int>()
        var duplicates = Set<Int>()
        var outOfRange = Set<Int>()
        for index in indices {
            guard index >= 0, index < count else {
                outOfRange.insert(index)
                continue
            }
            if !seen.insert(index).inserted { duplicates.insert(index) }
        }
        return (Set(0..<count).subtracting(seen), duplicates, outOfRange)
    }

    static func classificationInstructions(count: Int) -> String {
        """
        You classify location stays for a travel diary app. You MUST return exactly one classification for EVERY numbered stay index (0 through \(count - 1)). Never skip an index, and never classify a (context) line.
        Rules:
        1. "destination" = a place the user intentionally visited and spent meaningful time. "transit" = merely passing through en route: airports, train stations, ports, flight connections, gas/rest stops, driving through.
        2. Use the numbers on each line. A short stay (under ~2h) with a large "km from prev" jump just before or after it is usually the station, port, or terminal serving a nearby longer stay — the LONGER stay nearby is the destination.
        3. A short stay immediately after leaving home, or immediately before returning home, is almost always transit (the terminal before/after the actual trip).
        4. A stay tagged "overnight" is almost always a destination. Island-hopping or multi-city trips: each island/city with an overnight stay = destination.
        5. A numbered stay tagged AIRPORT spans 24 hours or more (shorter airport stays are pre-classified as transit): usually an airport hotel during a multi-day stopover — judge it from context.
        6. A stay line may carry CALENDAR: "…" — the user's calendar event overlapping that stay. An occasion (a wedding, a conference, a festival) supports "destination"; it never overrides rules 2-3 on its own.
        7. When uncertain, prefer "destination" - the user can reclassify later.
        """
    }

    /// The timeline renders the batch's chronological span from
    /// `ordered` (the full classification-ordered sequence): numbered `[i]`
    /// lines are the stays to classify, carrying duration, home distance,
    /// **km-from-previous-stay**, an **overnight** tag (spans solar 03:00 —
    /// the same convention the heuristic rules use), and island/metro
    /// identity; unnumbered `(context)` lines are the settled neighbours —
    /// home runs collapsed — plus up to `promptContextSpan` stays on each
    /// side, so ports, airports, and homecomings sit in view exactly where
    /// they occur.
    /// Internal (not private) for the prompt-shape tests; `calendarHints`
    /// maps stay id → the occasion line rendered as `CALENDAR: "…"`
    /// (instructions rule 6). When `ordered` is nil the method fetches the
    /// sequence itself; fixtures whose stays were never saved fall back to
    /// rendering the batch alone. A failed read throws.
    func buildPrompt(stays physicalBatch: [Stay], ordered: [Stay]? = nil, calendarHints: [UUID: String] = [:],
                     in context: ModelContext? = nil) throws -> String {
        try classificationPromptSnapshot(stays: physicalBatch, ordered: ordered, timeZone: .current,
            in: context ?? modelContext).rendered(calendarHints: calendarHints)
    }

    /// Canonical order for place rows: UUID, then physical identity for twins.
    nonisolated static func promptPlaceOrder(_ lhs: (id: UUID, row: PersistentIdentifier),
                                             _ rhs: (id: UUID, row: PersistentIdentifier)) -> Bool {
        if lhs.id != rhs.id { return lhs.id.uuidString < rhs.id.uuidString }
        return String(describing: lhs.row) < String(describing: rhs.row)
    }

    /// The values `buildPrompt` renders, from required reads: a failed read
    /// throws instead of rendering an empty home or timeline. Every value is
    /// independent of fetch order and of earlier work in the process, so the
    /// apply unit can rebuild it and compare.
    func classificationPromptSnapshot(stays physicalBatch: [Stay], ordered: [Stay]?, timeZone: TimeZone,
                                      in context: ModelContext) throws -> ClassificationPromptSnapshot {
        let homes = try context.fetch(FetchDescriptor<Home>(predicate: #Predicate { $0.endedAt == nil }))
            .filter { !$0.isDeleted }
            .sorted { Self.promptPlaceOrder(($0.id, $0.persistentModelID), ($1.id, $1.persistentModelID)) }
        let routinePlaces = try context.fetch(FetchDescriptor<RoutinePlace>(
            predicate: #Predicate { $0.isActive == true && $0.endedAt == nil }))
            .filter { !$0.isDeleted }
            .sorted { Self.promptPlaceOrder(($0.id, $0.persistentModelID), ($1.id, $1.persistentModelID)) }
        // A temporary home is context only for a batch its dates cover.
        // Collapsing twins orders by start, then UUID.
        let temporaryHomes = HomeAnchors.collapsingTwins(
            try context.fetch(FetchDescriptor<TemporaryHome>()).filter { !$0.isDeleted }
        ).filter { home in physicalBatch.contains { home.isActive(at: $0.startTime) } }

        // UUID twins are one logical stay: one numbered line each, and never
        // their own neighbour or a context line beside themselves.
        let stays = Self.logicalClassificationBatch(physicalBatch)
        let fullSequence = try ordered ?? context.fetch(FetchDescriptor<Stay>())
            .filter { !$0.isDeleted }.sorted(by: Self.classificationOrder)
        let orderedSequence = Self.logicalClassificationTimeline(fullSequence, batch: physicalBatch)
        var indexByID: [UUID: Int] = [:]
        for (i, s) in orderedSequence.enumerated() { indexByID[s.id] = i }
        var batchIndexByID: [UUID: Int] = [:]
        for (i, s) in stays.enumerated() { batchIndexByID[s.id] = i }

        // Every numbered stay MUST render, including unsaved fixtures.
        // Use a window around each batch stay, bounded by batch count × (2 × span + 1),
        // so a batch mixing import history and current-journey stays cannot render the intervening years.
        var timeline: [Stay] = stays
        let batchIndices = stays.compactMap { indexByID[$0.id] }
        if !batchIndices.isEmpty {
            var keep = Set<Int>()
            for index in batchIndices {
                let lo = max(0, index - promptContextSpan)
                let hi = min(orderedSequence.count - 1, index + promptContextSpan)
                for k in lo...hi { keep.insert(k) }
            }
            let span = keep.sorted().map { orderedSequence[$0] }
            let spanIDs = Set(span.map(\.id))
            if stays.allSatisfy({ spanIDs.contains($0.id) }) {
                timeline = span
            }
        }

        /// Whole-km distance from the stay's TRUE chronological predecessor
        /// (falling back to the batch-array predecessor for unsaved fixtures).
        func kmFromPrevious(_ stay: Stay) -> Int? {
            var prev: Stay?
            if let i = indexByID[stay.id], i > 0 {
                prev = orderedSequence[i - 1]
            } else if let b = batchIndexByID[stay.id], b > 0 {
                prev = stays[b - 1]
            }
            guard let prev else { return nil }
            return Int(HomeOrbit.greatCircleKm(prev.centroidLatitude, prev.centroidLongitude,
                stay.centroidLatitude, stay.centroidLongitude).rounded())
        }

        func place(_ name: String?, _ area: String?, _ country: String?, _ radiusKm: Double)
            -> ClassificationPromptSnapshot.Place {
            .init(name: name ?? "", administrativeArea: area, country: country, radiusKm: Int(radiusKm))
        }
        return ClassificationPromptSnapshot(
            homes: homes.map { place($0.label, $0.administrativeArea, $0.country, $0.radiusKm) },
            temporaryHomes: temporaryHomes.map {
                place($0.label.isEmpty ? $0.locality : $0.label, $0.administrativeArea, $0.country, $0.radiusKm)
            },
            routinePlaces: routinePlaces.map(\.label),
            lines: timeline.map { stay in
                let index = batchIndexByID[stay.id]
                return .init(index: index, locality: stay.locality, region: stay.islandName ?? stay.metroName,
                    country: stay.country, durationMinutes: stay.durationMinutes, category: stay.category,
                    isAirport: stay.isAirport,
                    homeDistanceKm: ClassificationPromptSnapshot.homeDistanceKm(stay.distanceFromHomeKm),
                    kmFromPrevious: index == nil ? nil : kmFromPrevious(stay),
                    start: stay.startTime, end: stay.endTime,
                    overnight: CollectionsAggregator.intervalCrossesSolarHour(
                        start: stay.startTime, end: stay.endTime, longitude: stay.centroidLongitude, hour: 3))
            },
            ids: stays.map(\.id), timeZone: timeZone)
    }

    /// Format distance from home for the AI prompt.
    /// Handles the edge case where no home is configured (greatestFiniteMagnitude).
    nonisolated func formattedHomeDistance(_ km: Double) -> String {
        ClassificationPromptSnapshot.homeDistanceKm(km).map { "\($0)km from home" } ?? "no home configured"
    }

    // MARK: - Heuristic Fallback

    /// Rule-based classification when Foundation Models is unavailable — the
    /// classifier every non-Apple-Intelligence device lives on. The rules are
    /// deterministic ports of the FM prompt's instructions (rules 2–5 there),
    /// applied most-specific-first; anything no transit rule claims is a
    /// destination (the prompt's rule 7: when uncertain, prefer destination).
    ///
    /// Calendar hints are deliberately NOT consulted here: the FM prompt's
    /// rule 6 allows them only as destination corroboration that "never
    /// overrides rules 2-3 on its own", and destination is already
    /// this engine's default — a hint could change an outcome only by
    /// overriding a transit rule, which is exactly what rule 6 forbids.
    func classifyWithHeuristics(stays: [Stay], ordered suppliedTimeline: [Stay]? = nil,
                                in context: ModelContext? = nil) -> Int {
        let context = context ?? modelContext
        var classified = 0
        let twentyFourHoursInMinutes = 24 * 60

        // Use true chronological neighbours; the fallback batch may contain only sparse stays skipped by the model.
        // UUID twins are one logical stay: decided once with real neighbours, copied to every eligible copy.
        let eligible = stays.filter { $0.category == .unclassified && !$0.userOverridden }
        let copies = Dictionary(grouping: eligible, by: \.id)
        let ordered = Self.logicalClassificationTimeline(suppliedTimeline ?? ((try? context.fetch(
            FetchDescriptor<Stay>()
        )) ?? []).filter { !$0.isDeleted }.sorted(by: Self.classificationOrder), batch: eligible)
        var indexByID: [UUID: Int] = [:]
        for (idx, s) in ordered.enumerated() { indexByID[s.id] = idx }

        for stay in Self.logicalClassificationBatch(eligible) {
            let category: StayCategory
            let idx = indexByID[stay.id]
            let prev = idx.flatMap { $0 > 0 ? ordered[$0 - 1] : nil }
            let next = idx.flatMap { $0 < ordered.count - 1 ? ordered[$0 + 1] : nil }

            if stay.isAirport && stay.durationMinutes < twentyFourHoursInMinutes {
                // Airport transit takes precedence over duration heuristics; stays of 24 hours or more may be airport hotels.
                category = .transit
            } else if let idx, journeyBoundaryTransit(stay: stay, ordered: ordered, index: idx) {
                // Rule B (= FM rule 3): a short stay at the very start or end of
                // an away-from-home journey is the station/port/terminal before
                // (after) the actual destination.
                category = .transit
            } else if adjacentBaseTransit(stay: stay, prev: prev, next: next) {
                // Rule C (= FM rule 2): a very short stop right beside a long
                // nearby base, immediately before/after a big displacement, is
                // the base's departure/arrival point (island port, HSR station).
                category = .transit
            } else if stay.durationMinutes < 180 {
                let prevFar = prev.map { $0.distanceFromHomeKm > stay.distanceFromHomeKm + 50 } ?? false
                let nextFar = next.map { $0.distanceFromHomeKm > stay.distanceFromHomeKm + 50 } ?? false
                category = prevFar || nextFar ? .transit : .destination
            } else {
                category = .destination
            }

            for copy in copies[stay.id] ?? [] {
                copy.category = category
                heuristicClassifiedStayIDs.insert(copy.id)
                classified += 1
            }
        }

        return classified
    }

    /// Rule B: `stay` sits at a journey boundary (its chronological neighbour
    /// on one side is home/routine or nonexistent), lasts under 90 minutes
    /// (tighter than the FM prompt's "<2h" — the model applies that with
    /// judgment; a fixed rule at 2h would eat genuine short first stops),
    /// and the journey continues to somewhere meaningfully farther from home
    /// on the inward side — the classic station-before-the-city shape.
    ///
    /// Guards:
    ///   - Exactly ONE side may be the boundary. Both sides home (a lone
    ///     home → X → home errand) means there is no "actual destination"
    ///     this stay could be en route to.
    ///   - A stay spanning solar 03:00 is never claimed (FM rule 4: an
    ///     overnight stay is a destination; solar time mirrors
    ///     `CollectionsAggregator`'s overnight-flight heuristic).
    ///   - The inward walk stops at the next home/routine stay and is capped
    ///     (a years-long homeless import must not turn this into O(n²)).
    private func journeyBoundaryTransit(stay: Stay, ordered: [Stay], index: Int) -> Bool {
        guard stay.durationMinutes < 90 else { return false }

        func isBoundary(_ s: Stay?) -> Bool {
            guard let s else { return true }
            return s.category == .home || s.category == .routine
        }
        let prev = index > 0 ? ordered[index - 1] : nil
        let next = index < ordered.count - 1 ? ordered[index + 1] : nil
        let atStart = isBoundary(prev)
        let atEnd = isBoundary(next)
        guard atStart != atEnd else { return false }

        if CollectionsAggregator.intervalCrossesSolarHour(
            start: stay.startTime, end: stay.endTime,
            longitude: stay.centroidLongitude, hour: 3
        ) {
            return false
        }

        let step = atStart ? 1 : -1
        var i = index + step
        var walked = 0
        while i >= 0 && i < ordered.count && walked < 60 {
            let candidate = ordered[i]
            if candidate.category == .home || candidate.category == .routine { break }
            if candidate.distanceFromHomeKm > stay.distanceFromHomeKm + 30 { return true }
            i += step
            walked += 1
        }
        return false
    }

    /// Rule C identifies a port or station beside a long base via displacement on the opposite side.
    /// Align the under-90-minute cap with rule B; use the same solar-03:00 overnight exemption.
    /// Home and routine neighbours cannot serve as the base.
    private func adjacentBaseTransit(stay: Stay, prev: Stay?, next: Stay?) -> Bool {
        guard stay.durationMinutes < 90, let prev, let next else { return false }

        if CollectionsAggregator.intervalCrossesSolarHour(
            start: stay.startTime, end: stay.endTime,
            longitude: stay.centroidLongitude, hour: 3
        ) {
            return false
        }

        func kmBetween(_ a: Stay, _ b: Stay) -> Double {
            CLLocation(latitude: a.centroidLatitude, longitude: a.centroidLongitude)
                .distance(from: CLLocation(latitude: b.centroidLatitude, longitude: b.centroidLongitude)) / 1000.0
        }
        func isBase(_ s: Stay) -> Bool {
            (s.category == .destination || s.category == .unclassified)
                && s.durationMinutes >= 360
                && kmBetween(stay, s) <= 25
        }
        func isFarSide(_ s: Stay) -> Bool {
            kmBetween(stay, s) >= 30
        }

        return (isBase(prev) && isFarSide(next)) || (isBase(next) && isFarSide(prev))
    }
}
