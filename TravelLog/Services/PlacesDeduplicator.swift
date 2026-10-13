//
//  PlacesDeduplicator.swift
//  TravelLog
//

import Foundation
import SwiftData
import CoreLocation
import os.log

/// Collapses duplicate **active** `Home` and `RoutinePlace` rows that arise
/// when the same logical place is created independently on two devices.
///
/// # Why this exists
///
/// `onboardingComplete` is device-local (`@AppStorage`), so a second device on
/// the same iCloud account runs the full onboarding — creating its own Home and
/// RoutinePlace rows — *before* CloudKit sync delivers the first device's rows.
/// Onboarding's inserts are unconditional (no fetch-before-insert, no auto-end,
/// unlike Settings' add-home path), and these two models — alone among the
/// store's types that can duplicate across devices — never had a deduplicator.
/// Result: two "current" homes / routine places, both with `endedAt == nil`,
/// which Settings' `isCurrent` filter can't hide because both are genuinely
/// active.
///
/// # The rule: pure proximity
///
/// Two active rows are the *same* place iff their coordinates are within a
/// threshold; far-apart active rows are left untouched (a user who genuinely
/// set two different homes keeps both). Home uses **1 km** — the same
/// "same home vs. moved" threshold Settings' edit-home path already applies
/// (`distance > 1000` → new home version; else edit in place). RoutinePlace
/// uses a tighter **250 m**: routine places are finer-grained (default radius
/// 500 m) and two distinct ones can sit closer together, while the same place
/// picked on two devices lands within map-tap / GPS jitter.
///
/// # Safety
///
/// The survivor is chosen deterministically on the
/// IMMUTABLE `id` — NOT `startedAt`, which `applyHomeChangeCore` backdates on
/// an ordinary Settings coverage edit, so two devices mid-propagation can see
/// different values for the same row and a startedAt-keyed pick would
/// delete-war to zero. The id never changes after insert, so every device
/// always agrees on the survivor; the survivor absorbs the group's earliest
/// `startedAt` so the oldest coverage window is preserved regardless of which
/// row wins. `nonisolated` so the launch / remote-notification
/// `Task.detached` wrappers genuinely run off the main actor.
nonisolated enum PlacesDeduplicator {

    private static let logger = Logger(
        subsystem: "com.travellog.app",
        category: "PlacesDeduplicator"
    )

    /// Single-flight per container, as `YearWrappedDeduplicator` keys it: the app
    /// has one container, and tests on separate containers never collide.
    private static let runningContainers = OSAllocatedUnfairLock(initialState: Set<ObjectIdentifier>())

    #if DEBUG
    /// Keyed by container so a parallel importer test's restore is unaffected.
    nonisolated(unsafe) static var failOverrideFetchForTestingContainer: ModelContainer?
    #endif

    /// Two active homes within this distance (meters) are the same home.
    /// Matches Settings' existing "same home vs. relocated" threshold.
    static let homeProximityMeters: Double = 1000

    /// Two active routine places within this distance (meters) are the same
    /// place. Tighter than homes — routine places cluster more densely.
    static let routineProximityMeters: Double = 250

    /// Device-local `[loserUUID: survivorUUID]` map of every Home this device
    /// collapsed. A correction authored against the loser on a lagging device
    /// can arrive after the loser row is gone; the map is the only record of
    /// where it belongs. Entries are never evicted (collapses need two devices
    /// onboarding the same place, so the map stays tiny) and chains are
    /// compacted to the newest survivor. Only a device that performed the
    /// collapse can replay it; Delete Everything clears the map with the
    /// overrides it would repair.
    static let homeAliasesKey = "homeDedupAliases_v1"

    /// One collapsed Home: `loser` was deleted in favour of `survivor`.
    struct HomeAlias: Hashable, Sendable {
        let loser: UUID
        let survivor: UUID
    }

    /// False when the pass did not run to its end (single-flight, fetch or save).
    @discardableResult
    static func deduplicateAll(
        modelContainer: ModelContainer,
        defaults: UserDefaults = .standard
    ) async -> Bool {
        let containerID = ObjectIdentifier(modelContainer)
        let alreadyRunning = runningContainers.withLock { running in
            !running.insert(containerID).inserted
        }
        guard !alreadyRunning else {
            logger.debug("Deduplication already in progress, skipping.")
            return false
        }
        defer { _ = runningContainers.withLock { $0.remove(containerID) } }

        let context = ModelContext(modelContainer)
        let loggedAliases = defaults.dictionary(forKey: homeAliasesKey)
        do {
            let titleInputsBefore = try TripTitleStore
                .fetchActiveHomeTitleInputs(in: context)
            let collapsed = try deduplicateHomes(in: context)
            let aliases = mergingHomeAliases(
                loadHomeAliases(defaults: defaults), collapsed)
            // Replay after this pass's own collapse, so a late row naming a
            // loser deleted just now or on an earlier launch lands too.
            let rebound = try rebindAliasedOverrides(in: context, aliases: aliases)
            let routinesMerged = try deduplicateRoutinePlaces(in: context)
            let titleInputsChanged = try TripTitleStore
                .invalidateAllGeneratedTitlesIfActiveHomesChanged(
                    from: titleInputsBefore,
                    in: context)
            guard collapsed.count + rebound + routinesMerged > 0 || titleInputsChanged else { return true }
            // Log before the save: a kill after the delete commits must not
            // lose the alias. A kill before it leaves an alias whose loser
            // still exists, which replay ignores and the next pass re-derives.
            if !collapsed.isEmpty { storeHomeAliases(aliases, defaults: defaults) }
            do {
                try context.save()
            } catch {
                defaults.set(loggedAliases, forKey: homeAliasesKey)
                throw error
            }
            // Bookkeeping only: the committed collapse and its aliases stand.
            let recorded = (try? TripTitleStore.recordActiveHomeTitleFingerprint(
                in: context)) != nil
            logger.info("Collapsed \(collapsed.count) duplicate home(s) and \(routinesMerged) duplicate routine place(s); rebound \(rebound) late correction(s).")
            return recorded
        } catch {
            context.rollback()
            logger.error("Place deduplication failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Home aliases

    static func loadHomeAliases(defaults: UserDefaults) -> [UUID: UUID] {
        var aliases: [UUID: UUID] = [:]
        for (key, value) in defaults.dictionary(forKey: homeAliasesKey) ?? [:] {
            // Malformed entries are skipped, never guessed.
            guard let loser = UUID(uuidString: key),
                  let text = value as? String,
                  let survivor = UUID(uuidString: text),
                  loser != survivor else { continue }
            aliases[loser] = survivor
        }
        return aliases
    }

    static func storeHomeAliases(_ aliases: [UUID: UUID], defaults: UserDefaults) {
        guard !aliases.isEmpty else {
            defaults.removeObject(forKey: homeAliasesKey)
            return
        }
        var stored: [String: String] = [:]
        for (loser, survivor) in aliases {
            stored[loser.uuidString] = survivor.uuidString
        }
        defaults.set(stored, forKey: homeAliasesKey)
    }

    /// Adds `collapsed` and repoints every earlier alias whose survivor just
    /// lost, so each entry names the newest survivor directly.
    static func mergingHomeAliases(
        _ existing: [UUID: UUID], _ collapsed: [HomeAlias]
    ) -> [UUID: UUID] {
        var aliases = existing
        for alias in collapsed where alias.loser != alias.survivor {
            aliases[alias.loser] = alias.survivor
            for (loser, survivor) in aliases where survivor == alias.loser {
                aliases[loser] = alias.survivor
            }
        }
        return aliases.filter { $0.key != $0.value }
    }

    /// Re-points each correction whose Home is a logged loser with no row in
    /// this store to the end of its alias chain, when that Home row exists.
    /// A row whose Home is merely missing (not logged) is left alone: missing
    /// rows during sync are not deletions. Reads every Home row, ended ones
    /// included, and every override; a failed read throws. Does not save.
    static func rebindAliasedOverrides(
        in context: ModelContext, aliases: [UUID: UUID]
    ) throws -> Int {
        guard !aliases.isEmpty else { return 0 }
        let overrides = try fetchAllOverrides(in: context).filter { !$0.isDeleted }
        let orphanedIDs = Set(overrides.compactMap(\.homeID))
            .filter { aliases[$0] != nil }
        guard !orphanedIDs.isEmpty else { return 0 }
        let homeIDs = Set(try context.fetch(FetchDescriptor<Home>())
            .filter { !$0.isDeleted }.map(\.id))
        var targets: [UUID: UUID] = [:]
        for loser in orphanedIDs where !homeIDs.contains(loser) {
            var current = aliases[loser]
            var visited: Set<UUID> = [loser]
            while let next = current, !homeIDs.contains(next) {
                guard visited.insert(next).inserted else { current = nil; break }
                current = aliases[next]
            }
            if let terminal = current { targets[loser] = terminal }
        }
        var rebound = 0
        for row in overrides {
            guard let homeID = row.homeID, let target = targets[homeID] else { continue }
            row.homeID = target
            rebound += 1
        }
        return rebound
    }

    // MARK: - Home

    /// Mutates `context` (deletes duplicate losers, fills survivor's nil
    /// geocode fields). Does NOT save — the caller saves once and logs the
    /// returned loser→survivor pairs (one per deleted row).
    /// Internal so the JSON importer can collapse its transient onboarding
    /// Home twin before deciding whether restored title artifacts still match
    /// the final prompt context. The caller owns the surrounding transaction.
    static func deduplicateHomes(in context: ModelContext) throws -> [HomeAlias] {
        let active = try context.fetch(FetchDescriptor<Home>(
            predicate: #Predicate { $0.endedAt == nil }
        ))
        guard active.count > 1 else { return [] }

        var collapsed: [HomeAlias] = []
        for group in proximityGroups(active.map { ($0.latitude, $0.longitude) },
                                     thresholdMeters: homeProximityMeters) {
            let members = group.map { active[$0] }
            // Cross-device-deterministic survivor: smallest id. The key must
            // be IMMUTABLE — `applyHomeChangeCore` backdates `startedAt` on a
            // Settings coverage edit, so a startedAt key can differ between
            // two devices' mid-propagation views and each would delete the
            // other's pick (delete-war to zero active homes). `id` never
            // changes after insert, so every device agrees.
            let survivor = members.min { $0.id.uuidString < $1.id.uuidString }!
            // Safety net (matches HexVisitDeduplicator): if the survivor isn't
            // uniquely determined (shared id), skip rather than risk converging
            // to zero. With distinct ids this never fires.
            if members.filter({ $0.id == survivor.id }).count > 1 {
                logger.info("Skipped a home group with no uniquely-determined survivor (shared id).")
                continue
            }
            // Deterministic DONOR order: the nil-fill fields
            // below take the FIRST donor carrying a value, and `members`
            // rides an unsorted fetch — two devices could absorb different
            // labels/geocode fields onto the same deterministic survivor and
            // ping-pong via CloudKit. Same immutable-id key as the survivor
            // pick, so every device absorbs identically.
            let donors = members
                .filter { $0.id != survivor.id }
                .sorted { $0.id.uuidString < $1.id.uuidString }
            for dup in donors {
                // Absorb the earliest coverage window: the id rule must not
                // shrink home history when a later-id row started earlier
                // (idempotent `min`, order-independent → convergent).
                survivor.startedAt = min(survivor.startedAt, dup.startedAt)
                if survivor.label.isEmpty { survivor.label = dup.label }
                if survivor.locality == nil { survivor.locality = dup.locality }
                if survivor.administrativeArea == nil { survivor.administrativeArea = dup.administrativeArea }
                if survivor.country == nil {
                    survivor.country = dup.country
                    survivor.isoCountryCode = dup.isoCountryCode
                }
                // Keep the WIDER radius (idempotent `max`, like HexVisit's
                // visitCount). If a device customized a larger home radius
                // before sync converged, collapsing onto the default-radius
                // survivor must not shrink home coverage (which could
                // reclassify a home stay as a trip). Order-independent and
                // identical on every device → convergent.
                survivor.radiusKm = max(survivor.radiusKm, dup.radiusKm)
                // `HomeAreaOverride.homeID` is a STORED Home id (V15) — the
                // one reference the "no @Model references a Home" safety
                // doc predates. Re-point before deleting, or roughly half
                // of two-device onboardings orphan every correction the
                // losing device taught: attached to no ring, inert in
                // membership, yet still listed in Home Area Places.
                // Loser→survivor is
                // deterministic on both devices, so the rows converge; the
                // override deduplicator then folds any resulting identical
                // pairs on its next pass.
                // Rows arriving after this save are re-pointed by
                // `rebindAliasedOverrides` from the returned alias.
                let dupID = dup.id
                let orphaned = try fetchOverrides(homeID: dupID, in: context)
                for row in orphaned { row.homeID = survivor.id }
                context.delete(dup)
                collapsed.append(HomeAlias(loser: dupID, survivor: survivor.id))
            }
        }
        return collapsed
    }

    private static func fetchOverrides(homeID: UUID, in context: ModelContext) throws -> [HomeAreaOverride] {
        #if DEBUG
        if let failing = failOverrideFetchForTestingContainer, failing === context.container {
            throw CocoaError(.fileReadUnknown)
        }
        #endif
        return try context.fetch(FetchDescriptor<HomeAreaOverride>(
            predicate: #Predicate { $0.homeID == homeID }))
    }

    private static func fetchAllOverrides(in context: ModelContext) throws -> [HomeAreaOverride] {
        #if DEBUG
        if let failing = failOverrideFetchForTestingContainer, failing === context.container {
            throw CocoaError(.fileReadUnknown)
        }
        #endif
        return try context.fetch(FetchDescriptor<HomeAreaOverride>())
    }

    // MARK: - RoutinePlace

    private static func deduplicateRoutinePlaces(in context: ModelContext) throws -> Int {
        let active = try context.fetch(FetchDescriptor<RoutinePlace>(
            predicate: #Predicate { $0.isActive == true && $0.endedAt == nil }
        ))
        guard active.count > 1 else { return 0 }

        var merged = 0
        for group in proximityGroups(active.map { ($0.latitude, $0.longitude) },
                                     thresholdMeters: routineProximityMeters) {
            let members = group.map { active[$0] }
            // Same immutable-id survivor + ambiguous-id safety net as homes.
            let survivor = members.min { $0.id.uuidString < $1.id.uuidString }!
            if members.filter({ $0.id == survivor.id }).count > 1 {
                logger.info("Skipped a routine-place group with no uniquely-determined survivor (shared id).")
                continue
            }
            // Same deterministic donor order as the Home loop.
            let donors = members
                .filter { $0.id != survivor.id }
                .sorted { $0.id.uuidString < $1.id.uuidString }
            for dup in donors {
                survivor.startedAt = min(survivor.startedAt, dup.startedAt)
                if survivor.label.isEmpty { survivor.label = dup.label }
                // Keep the wider radius — see the Home loop for rationale.
                survivor.radiusMeters = max(survivor.radiusMeters, dup.radiusMeters)
                context.delete(dup)
                merged += 1
            }
        }
        return merged
    }

    // MARK: - Shared proximity grouping

    /// Connected components of points within `thresholdMeters` of each other
    /// (union-find). Proximity isn't transitive, but realistic duplicate sets
    /// are pairs (one extra row per extra device), so chaining is a non-issue
    /// at this scale (homes/routine places number in the low single digits).
    /// Returns only groups of size > 1. `internal` for unit testing.
    static func proximityGroups(
        _ coords: [(lat: Double, lon: Double)],
        thresholdMeters: Double
    ) -> [[Int]] {
        let n = coords.count
        guard n > 1 else { return [] }

        var parent = Array(0..<n)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        let locations = coords.map { CLLocation(latitude: $0.lat, longitude: $0.lon) }
        for i in 0..<n {
            for j in (i + 1)..<n where locations[i].distance(from: locations[j]) <= thresholdMeters {
                union(i, j)
            }
        }

        var byRoot: [Int: [Int]] = [:]
        for i in 0..<n { byRoot[find(i), default: []].append(i) }
        return byRoot.values.filter { $0.count > 1 }
    }
}
