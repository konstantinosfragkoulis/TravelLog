//
//  TripClassifier+HomeReconciliation.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import Foundation
import CryptoKit
import SwiftData
import CoreLocation
import WidgetKit
import os.log

extension TripClassifier {

    /// A Home or RoutinePlace coverage reconciliation unit's result. Only
    /// `committed` and `placeMissing` discharge a pending reconciliation;
    /// the follow-up pipeline pass is separate work with its own triggers.
    nonisolated enum CoverageReconciliationOutcome: Sendable, Equatable {
        /// The unit saved (or had nothing to change); `resetCount` stays
        /// now await the pipeline.
        case committed(resetCount: Int)
        /// Saved like `committed`, but a completed trip the edit covers was
        /// left whole while the store may still be hydrating: its stays do
        /// not give every place its stored summary names, so its away stays
        /// may not have synced yet (`TripTitleStore.mayDeriveSummary`). The
        /// debt stays queued, and a drain after hydration settles reconciles it.
        case deferred(resetCount: Int)
        /// The edited row is not in this store. Only rows this device
        /// committed are queued, so absence means a local collapse or wipe.
        case placeMissing
        /// Cancelled while queued behind the pipeline; nothing ran.
        case cancelled
        /// A required read or the save failed; the unit rolled back.
        case failed

        var resetCount: Int {
            switch self {
            case .committed(let count), .deferred(let count): count
            case .placeMissing, .cancelled, .failed: 0
            }
        }

        var isSettled: Bool {
            switch self {
            case .committed, .placeMissing: true
            case .deferred, .cancelled, .failed: false
            }
        }

        /// The unit saved (or had nothing to change), deferred or not.
        var didCommit: Bool {
            switch self {
            case .committed, .deferred: true
            case .placeMissing, .cancelled, .failed: false
            }
        }
    }

    /// Reconcile Settings home additions and moves; onboarding predates tracking.
    /// Detach reset stays because preFilterStays only processes unclassified rows and home stays cannot remain trip members.
    /// Recompute distance with StayClusterer.closestHomeDistanceKm because home history changed.
    /// Explicit actions queue behind an in-flight pipeline; zero resets skips the pipeline pass.
    /// `onSettled` runs right after the reconciliation unit settles, before the long pipeline pass.
    /// `backdatesStart: false` is for dates the user picked: the unit keeps them as given.
    /// Favourites live on the main actor; the unit reads them inside its gate.
    @discardableResult
    func applyHomeChange(
        homeID: UUID,
        backdatesStart: Bool = true,
        gate: PipelineGate = .shared,
        pinnedTripIDs: @escaping @MainActor @Sendable () -> Set<UUID> = { PinnedTripsStorage.shared.pinnedIDs },
        onSettled: (@MainActor @Sendable () -> Void)? = nil
    ) async -> CoverageReconciliationOutcome {
        guard await takeLatchQueued(waiting: {
            logger.debug("Pipeline running; home-change reconciliation queued.")
        }) else { return .cancelled }
        defer { isRunning = false }

        let outcome = await gate.runReturning(touching: [.home, .stay, .trip]) {
            guard await self.primeHomeShapes() else {
                return CoverageReconciliationOutcome.failed
            }
            let pinned = await pinnedTripIDs()
            return await self.applyHomeChangeCore(
                homeID: homeID, backdatesStart: backdatesStart, pinnedTripIDs: pinned)
        }
        if outcome.isSettled, let onSettled { await onSettled() }
        let resetCount = outcome.resetCount
        guard resetCount > 0 else { return outcome }
        _ = await runPipelineStagesWithGates(maxStaysPerCall: nil, gate: gate)

        logger.info("Home change: reset \(resetCount) stay(s) inside the new home ring; re-running pipeline.")
        _ = await generateTitlesStage(
            maxTripsPerCall: nil,
            applyGate: gate)
        if lastPipelineMadeChanges {
            await MainActor.run { WidgetCenter.shared.reloadAllTimelines() }
        }
        return outcome
    }

    /// The deterministic half of `applyHomeChange` (backdate + reset +
    /// detach + distance recompute + save), split from the pipeline re-run
    /// so tests can drive it through the narrow `preFilterStays` /
    /// `assembleTrips` / `closeStaleOpenTrips` seams without Stage 2 in
    /// the loop. Caller must hold `isRunning`. Every read is
    /// required and precedes the first mutation; a failed save, or a summary
    /// whose home-place read failed, rolls the unit back.
    internal func applyHomeChangeCore(
        homeID: UUID, backdatesStart: Bool = true, pinnedTripIDs: Set<UUID> = []
    ) -> CoverageReconciliationOutcome {
        let homePredicate = #Predicate<Home> { $0.id == homeID }
        let fetchedHome: Home?
        do {
            #if DEBUG
            if failHomeReadForTesting { throw CocoaError(.fileReadUnknown) }
            #endif
            fetchedHome = try modelContext.fetch(
                FetchDescriptor<Home>(predicate: homePredicate)).first
        } catch {
            logger.error("Home change skipped; edited home unreadable: \(error.localizedDescription)")
            return .failed
        }
        guard let home = fetchedHome else { return .placeMissing }

        guard let allStays = fetchReconciliationStays(orSkip: "Home change") else { return .failed }
        guard !allStays.isEmpty else { return .committed(resetCount: 0) }
        guard let dependencies = fetchHomeAreaDependencies(orSkip: "Home change") else { return .failed }
        let overrides = dependencies.overrides
        guard let curated = curatedTripIDs(
            stays: allStays, pinnedTripIDs: pinnedTripIDs, orSkip: "Home change") else { return .failed }

        // 1. Backdate to the contiguous-arrival effective date. Only ever
        // moves EARLIER — a manual future-dated startedAt is respected, and
        // a date the user picked is never moved.
        let points = backdatesStart ? allStays.map {
            StayPoint(
                latitude: $0.centroidLatitude,
                longitude: $0.centroidLongitude,
                startTime: $0.startTime
            )
        } : []
        // Reset and backdate with the same geometry as matchesHome to preserve trips outside measured coverage;
        // a missing membership retains the withShapes circle fallback.
        let editedMembership = withShapes([Self.HomeRing(
            latitude: home.latitude, longitude: home.longitude,
            radiusKm: home.radiusKm, startedAt: home.startedAt, endedAt: home.endedAt,
            homeID: home.id
        )], overrides: overrides).first?.membership

        if let effective = Self.homeEffectiveStart(
            homeLatitude: home.latitude,
            homeLongitude: home.longitude,
            radiusKm: home.radiusKm,
            membership: editedMembership,
            stays: points
        ), effective < home.startedAt {
            home.startedAt = effective
        }

        // Read after the backdate, so the edited Home's ring carries its new start.
        let allAnchors = classificationAnchors(of: dependencies)
        let homeWindows = allAnchors.map { StayClusterer.HomeWindow($0) }
        let homeRings = withShapes(allAnchors.map { Self.HomeRing($0) }, overrides: overrides)

        // Reconcile detached completed trips here because assembly does not rebuild them or remove empty rows.
        // Only the in-ring reset captures these stays, so each becomes a future home boundary.
        var affectedCompletedTrips:
            [ObjectIdentifier: (trip: Trip, detached: [Stay])] = [:]
        var affectedOpenTrips: [ObjectIdentifier: Trip] = [:]

        func resetStay(_ stay: Stay) {
            if let trip = stay.trip {
                let identity = ObjectIdentifier(trip)
                if trip.isComplete {
                    affectedCompletedTrips[identity, default: (trip, [])]
                        .detached.append(stay)
                } else {
                    affectedOpenTrips[identity] = trip
                }
            }
            stay.category = .unclassified
            stay.trip = nil
            stay.orderInTrip = nil
            stay.distanceFromHomeKm = StayClusterer.closestHomeDistanceKm(
                latitude: stay.centroidLatitude,
                longitude: stay.centroidLongitude,
                atTime: stay.startTime,
                homes: homeWindows
            )
        }
        // A stay the user set, or one an edited trip holds, is the user's.
        func isUsers(_ stay: Stay) -> Bool {
            stay.userOverridden || stay.trip?.userEdited == true
        }
        // A curated trip holding a stay the edit covers keeps it, and is marked
        // edited below (`markSparedTripsEdited`).
        var spared = Set<UUID>()
        func spares(_ stay: Stay) -> Bool {
            guard let trip = stay.trip, curated.contains(trip.id) else { return false }
            spared.insert(trip.id)
            return true
        }
        // While the store may be hydrating, a completed trip whose stays do not
        // give every place its stored summary names is left whole: its away
        // stays may not have synced yet, and shrinking or deleting its row
        // would reach the device that holds them. Each trip is judged at the
        // first of its stays a pass below would reset, so before any of its
        // stays is detached; the unit then stays owed (`deferred`).
        var hydrating: Bool?
        var leftWhole: [ObjectIdentifier: Bool] = [:]
        func defers(_ stay: Stay) -> Bool {
            guard let trip = stay.trip, trip.isComplete else { return false }
            let identity = ObjectIdentifier(trip)
            if let judged = leftWhole[identity] { return judged }
            let leaves = !TripTitleStore.mayDeriveSummary(
                holdsNamedStays: TripTitleStore.holdsItsNamedStays(trip), hydrating: &hydrating)
            leftWhole[identity] = leaves
            return leaves
        }

        var resetCount = 0
        // In both passes below a temporary home's stamp goes only as its own
        // unit may free it: a newer copy's, or one of a declaration this device
        // does not hold, keeps its category and pair.
        func mayRelease(_ stay: Stay) -> Bool {
            Self.automaticReleaseAllows(
                stay, liveRevisions: dependencies.temporaryHomeRevisions,
                removedIDs: dependencies.removedTemporaryHomeIDs)
        }
        for stay in allStays where stay.startTime >= home.startedAt {
            // An ended Home claims nothing after its era (inclusive end, as
            // `matchesHome`): a late unit for it must not reset the trips
            // that came after the move.
            if let endedAt = home.endedAt, stay.startTime > endedAt { continue }
            guard !isUsers(stay) else { continue }
            // Same geometry as `matchesHome`: the measured membership when
            // one is attached, the declared circle otherwise (see
            // `editedMembership`), evaluated at the stay's own time.
            if let editedMembership {
                guard editedMembership.contains(
                    latitude: stay.centroidLatitude, longitude: stay.centroidLongitude,
                    at: stay.startTime
                ) else { continue }
            } else {
                let coordinate = CLLocationCoordinate2D(
                    latitude: stay.centroidLatitude, longitude: stay.centroidLongitude
                )
                guard home.contains(coordinate) else { continue }
            }
            guard !spares(stay), mayRelease(stay), !defers(stay) else { continue }
            resetStay(stay)
            resetCount += 1
        }

        // Unstamp stale home stays with the exact matchesHome predicate used by preFilterStays,
        // so shrinking or moving a ring can release stays outside its new coverage.
        for stay in allStays where stay.category == .home {
            guard !isUsers(stay) else { continue }
            if !Self.matchesHome(
                stayStart: stay.startTime,
                latitude: stay.centroidLatitude,
                longitude: stay.centroidLongitude,
                homes: homeRings
            ) {
                guard !spares(stay), mayRelease(stay), !defers(stay) else { continue }
                resetStay(stay)
                resetCount += 1
            }
        }
        let sparedTrips = markSparedTripsEdited(spared, stays: allStays)
        // The backdate, resets and unstamps above change the home-place inputs;
        // the recompute below must not read a snapshot from before this unit.
        TripTitleStore.invalidateHomePlaceIndex()

        // Assembly snapshots incomplete trips only after this reconciliation
        // returns. Clear titles now, while we still know that membership was
        // detached, so the already-smaller shape cannot become a false
        // carry-forward baseline for a title that described the old trip.
        for trip in affectedOpenTrips.values {
            TripTitleStore.invalidateGeneratedTitles(
                for: trip, in: modelContext)
        }

        // Delete fully absorbed trips; shrink survivors and invalidate generated titles after membership changes.
        // Preserve closeTrip semantics: the first detached home stay after the remaining stays is the new end boundary.
        var deletedGhostTrips = 0
        for (trip, detached) in affectedCompletedTrips.values {
            let remaining = trip.orderedStays
            // A remnant with no destination is errand residue, not a journey
            // (the assembleTrips all-transit rule): shrinking would keep a
            // completed trip whose destinationSummary/countryCodes are empty
            // — a blank ghost card. Detach the transit stays into the
            // tripless steady state the destination-only dirty gate
            // tolerates, and delete the row alongside the fully-emptied case.
            guard let first = remaining.first, let last = remaining.last,
                  remaining.contains(where: { $0.category == .destination }) else {
                for stay in remaining {
                    stay.trip = nil
                    stay.orderInTrip = nil
                }
                modelContext.delete(trip)
                deletedGhostTrips += 1
                continue
            }
            trip.startDate = first.startTime
            let homecoming = detached
                .filter { $0.startTime >= last.endTime }
                .map(\.startTime)
                .min()
            if let homecoming, homecoming < (trip.endDate ?? .distantFuture) {
                trip.endDate = homecoming
            }
            TripTitleStore.invalidateGeneratedTitles(
                for: trip, in: modelContext)
            // Judged before the detach (`defers`), never after it: no shrunk
            // trip still gives every name it stored.
            guard leftWhole[ObjectIdentifier(trip)] == false else {
                TripTitleStore.oweSummaryRefresh()
                continue
            }
            // A completed trip is never rebuilt by assembly, so a summary built
            // without its home-place filter would persist; roll back and keep the debt.
            guard trip.recomputeSummary() else {
                return rollBackUnreadableHomePlaces(unit: "Home change")
            }
        }
        if deletedGhostTrips > 0 {
            logger.info("Home change: deleted \(deletedGhostTrips) fully-absorbed completed trip(s).")
        }
        let leftWholeTrips = leftWhole.values.filter { $0 }.count
        if leftWholeTrips > 0 {
            logger.info("Home change: left \(leftWholeTrips) completed trip(s) whole until hydration settles.")
        }

        guard saveReconciliation(unit: "Home change", sparedTrips: sparedTrips) else { return .failed }
        return leftWholeTrips > 0 ? .deferred(resetCount: resetCount) : .committed(resetCount: resetCount)
    }

    /// The trips an ordinary coverage edit leaves whole, by logical id (every
    /// row of an id counts): edited, named, holding a stay the user set, a
    /// favourite, or with a photo choice. Such a trip is never absorbed or
    /// deleted here; only the user's own action takes it apart. Nil when a
    /// read fails: an unreadable photo table is not one without choices.
    func curatedTripIDs(
        stays: [Stay], pinnedTripIDs: Set<UUID>, orSkip unit: String
    ) -> Set<UUID>? {
        do {
            var ids = pinnedTripIDs
            ids.formUnion(try modelContext.fetch(FetchDescriptor<HiddenPhoto>()).map(\.tripID))
            ids.formUnion(try modelContext.fetch(FetchDescriptor<PinnedPhoto>()).map(\.tripID))
            var descriptor = FetchDescriptor<Trip>(predicate: #Predicate {
                $0.userEdited || $0.customName != nil
            })
            descriptor.propertiesToFetch = [\.id]
            ids.formUnion(try modelContext.fetch(descriptor).map(\.id))
            for stay in stays where stay.userOverridden {
                if let id = stay.trip?.id { ids.insert(id) }
            }
            return ids
        } catch {
            logger.error("\(unit, privacy: .public) skipped; trip choices unreadable: \(error.localizedDescription)")
            return nil
        }
    }

    /// Marks edited, in the coverage unit's own save, every row of each
    /// curated trip it left holding a stay it covers. Only that mark holds
    /// the trip through what follows: the follow-up pass and every later one
    /// would otherwise take an automatic trip apart (assembly detaches an
    /// open one and rebuilds it, and the confidence gate drops stays now
    /// inside a home area; Stage 1.5 judges its latest stays again). Edited,
    /// it keeps its members and id as any trip the user edited does. The mark
    /// is the user's own (`keptByTemporaryHome` stays false): a favourite,
    /// name or photo choice is the user engaging with the trip. Returns each
    /// trip it marked, none of whose rows the user had edited, with the stays
    /// it holds, for the device-local log of spared trips (`sparedTripsKey`)
    /// that lets the mark go once nothing the user chose holds the trip.
    @discardableResult
    func markSparedTripsEdited(_ spared: Set<UUID>, stays: [Stay]) -> [UUID: Set<UUID>] {
        guard !spared.isEmpty else { return [:] }
        var members: [UUID: Set<UUID>] = [:]
        var edited = Set<UUID>()
        for stay in stays where !stay.isDeleted {
            guard let trip = stay.trip, spared.contains(trip.id) else { continue }
            members[trip.id, default: []].insert(stay.id)
            if trip.userEdited { edited.insert(trip.id) }
        }
        for stay in stays {
            guard let trip = stay.trip, !trip.userEdited, spared.contains(trip.id) else { continue }
            trip.userEdited = true
        }
        return members.filter { !edited.contains($0.key) }
    }

    // MARK: - Spared trips

    /// Device-local JSON `[UUID: Set<UUID>]`: each trip a coverage unit marked
    /// edited only to spare it (`markSparedTripsEdited`), with the stays it
    /// held then, logged once that unit committed. The mark is released, on
    /// this device, by the first back half that finds the trip with exactly
    /// those stays and nothing the user chose (a favourite, a name, a photo
    /// choice, a stay the user set): the trip is automatic again, for
    /// assembly, import adoption, healing and Reclassify All. A trip whose
    /// stays changed since (a split, a merge, a stay the user moved) keeps the
    /// mark for good, since it may be the user's now. Delete All Data clears it.
    nonisolated static let sparedTripsKey = "coverageSparedTrips_v1"

    nonisolated static func sparedTrips(defaults: UserDefaults) -> [UUID: Set<UUID>] {
        guard let data = defaults.data(forKey: sparedTripsKey),
              let log = try? JSONDecoder().decode([UUID: Set<UUID>].self, from: data) else { return [:] }
        return log
    }

    /// Replaces the log and returns the bytes it replaced.
    @discardableResult
    nonisolated static func writeSparedTrips(_ log: [UUID: Set<UUID>], defaults: UserDefaults) -> Data? {
        let prior = defaults.data(forKey: sparedTripsKey)
        if log.isEmpty {
            defaults.removeObject(forKey: sparedTripsKey)
        } else if let data = try? JSONEncoder().encode(log) {
            defaults.set(data, forKey: sparedTripsKey)
        }
        return prior
    }

    nonisolated static func restoreSparedTrips(_ prior: Data?, defaults: UserDefaults) {
        if let prior {
            defaults.set(prior, forKey: sparedTripsKey)
        } else {
            defaults.removeObject(forKey: sparedTripsKey)
        }
    }

    /// The logged spared trips to release now (each holds its logged stays,
    /// every row still carries the coverage mark, and nothing the user chose
    /// holds it), and the entries that leave the log either way (released,
    /// gone, or changed since the mark). Throws on a failed read.
    func sparedTripReleases(pinnedTripIDs: Set<UUID>) throws -> (release: Set<UUID>, settled: Set<UUID>) {
        let log = Self.sparedTrips(defaults: hiddenLineageDefaults)
        guard !log.isEmpty else { return ([], []) }
        let ids = Array(log.keys)
        let rows = try modelContext.fetch(FetchDescriptor<Trip>(predicate: #Predicate { ids.contains($0.id) }))
        let tripsByID = Dictionary(grouping: rows.filter { !$0.isDeleted }, by: \.id)
        var hidden = FetchDescriptor<HiddenPhoto>(predicate: #Predicate { ids.contains($0.tripID) })
        hidden.propertiesToFetch = [\.tripID]
        var pinned = FetchDescriptor<PinnedPhoto>(predicate: #Predicate { ids.contains($0.tripID) })
        pinned.propertiesToFetch = [\.tripID]
        let chosen = Set(try modelContext.fetch(hidden).map(\.tripID))
            .union(try modelContext.fetch(pinned).map(\.tripID))
        var release = Set<UUID>()
        var settled = Set<UUID>()
        for (id, logged) in log {
            guard let trips = tripsByID[id] else {
                settled.insert(id)
                continue
            }
            let stays = trips.flatMap { $0.stays ?? [] }.filter { !$0.isDeleted }
            guard Set(stays.map(\.id)) == logged,
                  trips.allSatisfy({ $0.userEdited && !$0.keptByTemporaryHome }) else {
                settled.insert(id)
                continue
            }
            let curated = pinnedTripIDs.contains(id) || chosen.contains(id)
                || trips.contains { $0.customName != nil } || stays.contains(where: \.userOverridden)
            if !curated {
                release.insert(id)
                settled.insert(id)
            }
        }
        return (release, settled)
    }

    /// Lets go of the coverage mark on every logged spared trip nothing the
    /// user chose holds any more (`sparedTripReleases`), in the caller's
    /// unit, before assembly reads the trips; the log follows in that unit's
    /// save (`logPendingHiddenLineages`). A failed read releases nothing.
    /// Returns how many trips it released.
    func releaseSparedTrips(pinnedTripIDs: Set<UUID>) -> Int {
        let decision: (release: Set<UUID>, settled: Set<UUID>)
        let rows: [Trip]
        do {
            decision = try sparedTripReleases(pinnedTripIDs: pinnedTripIDs)
            let ids = Array(decision.release)
            rows = ids.isEmpty ? [] : try modelContext.fetch(
                FetchDescriptor<Trip>(predicate: #Predicate { ids.contains($0.id) }))
        } catch {
            logger.error("Spared-trip release skipped; read failed: \(error.localizedDescription)")
            return 0
        }
        guard !decision.settled.isEmpty else { return 0 }
        var log = Self.sparedTrips(defaults: hiddenLineageDefaults)
        for id in decision.settled { log[id] = nil }
        pendingSparedTrips = log
        guard !decision.release.isEmpty else { return 0 }
        for trip in rows where !trip.isDeleted { trip.userEdited = false }
        logger.info("Released the coverage mark on \(decision.release.count) trip(s) nothing the user chose holds.")
        return decision.release.count
    }

    func fetchReconciliationStays(orSkip unit: String) -> [Stay]? {
        do {
            #if DEBUG
            if failReconciliationStayReadForTesting { throw CocoaError(.fileReadUnknown) }
            #endif
            return try modelContext.fetch(FetchDescriptor<Stay>(
                sortBy: [SortDescriptor(\.startTime, order: .forward)]))
        } catch {
            logger.error("\(unit, privacy: .public) skipped; stays unreadable: \(error.localizedDescription)")
            return nil
        }
    }

    /// Rolls back a coverage reconciliation unit whose completed-trip summary
    /// could not read its home places. The unit commits once and its queue
    /// debt settles on commit, so a degraded summary is a failed unit.
    private func rollBackUnreadableHomePlaces(unit: String) -> CoverageReconciliationOutcome {
        modelContext.rollback()
        // Never serve a home-place snapshot built from rolled-back rows.
        TripTitleStore.invalidateHomePlaceIndex()
        logger.error("\(unit, privacy: .public) rolled back; home places unreadable for a trip summary.")
        return .failed
    }

    /// Saves a coverage reconciliation unit; a failure rolls it back whole.
    func saveReconciliation(unit: String, sparedTrips: [UUID: Set<UUID>] = [:]) -> Bool {
        do {
            #if DEBUG
            if shouldFailNextReconciliationSaveForTesting {
                shouldFailNextReconciliationSaveForTesting = false
                throw CocoaError(.fileWriteUnknown)
            }
            #endif
            try modelContext.save()
            if !sparedTrips.isEmpty {
                // Logged only once the mark committed, so the log never names
                // a mark the user set.
                var log = Self.sparedTrips(defaults: hiddenLineageDefaults)
                log.merge(sparedTrips) { _, new in new }
                Self.writeSparedTrips(log, defaults: hiddenLineageDefaults)
            }
            return true
        } catch {
            modelContext.rollback()
            // The unit's summaries read a home-place snapshot of rolled-back rows.
            TripTitleStore.invalidateHomePlaceIndex()
            logger.error("\(unit, privacy: .public) rolled back; save failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Received coverage

    /// Automatic settled stays no ordinary place claims any more: a `.home`
    /// stay no temporary home stamped that no Home or temporary home ring
    /// claims, a `.routine` stay no routine ring claims, each judged as the
    /// stale passes of the Home and routine units judge it. A Home or routine
    /// place edited on another device, or history that synced in after this
    /// device's own edit settled, leaves them with no unit owed here. Only
    /// tripless rows the user did not set count: a stay in a trip is that
    /// trip's. Nothing counts without a current Home. With `release`, frees
    /// them in one save for the next pass to judge again. Nil when a read or
    /// the save failed.
    func staleOrdinaryPlaceStayCount(release: Bool) -> Int? {
        let unit = "Received coverage repair"
        let home = StayCategory.home.rawValue
        let routine = StayCategory.routine.rawValue
        let stays: [Stay]
        do {
            stays = try modelContext.fetch(FetchDescriptor<Stay>(predicate: #Predicate {
                ($0.categoryRaw == home || $0.categoryRaw == routine)
                    && !$0.userOverridden && $0.trip == nil
            }))
        } catch {
            logger.error("\(unit, privacy: .public) skipped; stays unreadable: \(error.localizedDescription)")
            return nil
        }
        guard !stays.isEmpty else { return 0 }
        guard let dependencies = fetchHomeAreaDependencies(orSkip: unit) else { return nil }
        guard dependencies.homes.contains(where: \.isCurrent) else { return 0 }
        let anchors = classificationAnchors(of: dependencies)
        let homeRings = withShapes(anchors.map { HomeRing($0) }, overrides: dependencies.overrides)
        let routineRings = dependencies.routinePlaces.map {
            RoutineRing(latitude: $0.latitude, longitude: $0.longitude,
                        radiusMeters: $0.radiusMeters, startedAt: $0.startedAt, endedAt: $0.endedAt)
        }
        let stale = stays.filter { stay in
            if stay.category == .home {
                return stay.temporaryHomeID == nil && !Self.matchesHome(
                    stayStart: stay.startTime, latitude: stay.centroidLatitude,
                    longitude: stay.centroidLongitude, homes: homeRings)
            }
            return !Self.matchesRoutine(
                stayStart: stay.startTime, latitude: stay.centroidLatitude,
                longitude: stay.centroidLongitude, places: routineRings)
        }
        guard release, !stale.isEmpty else { return stale.count }
        let homeWindows = anchors.map { StayClusterer.HomeWindow($0) }
        for stay in stale {
            if stay.category == .home {
                stay.distanceFromHomeKm = StayClusterer.closestHomeDistanceKm(
                    latitude: stay.centroidLatitude, longitude: stay.centroidLongitude,
                    atTime: stay.startTime, homes: homeWindows)
            }
            stay.category = .unclassified
        }
        TripTitleStore.invalidateHomePlaceIndex()
        guard saveReconciliation(unit: unit) else { return nil }
        logger.info("Received coverage: freed \(stale.count) stay(s) no place claims any more.")
        return stale.count
    }

    /// Whether `staleOrdinaryPlaceStayCount` finds any, read outside the gate:
    /// the drain's discovery. Nil when unreadable.
    func hasStaleOrdinaryPlaceStays() async -> Bool? {
        guard await primeHomeShapes() else { return nil }
        return staleOrdinaryPlaceStayCount(release: false).map { $0 > 0 }
    }

    /// Frees the stays `staleOrdinaryPlaceStayCount` finds in one gated unit,
    /// then runs the pipeline so they are judged again.
    @discardableResult
    func releaseStaleOrdinaryPlaceStays(gate: PipelineGate = .shared) async -> CoverageReconciliationOutcome {
        guard await takeLatchQueued(waiting: {
            logger.debug("Pipeline running; received coverage repair queued.")
        }) else { return .cancelled }
        defer { isRunning = false }
        let outcome = await gate.runReturning(touching: [.stay]) {
            guard await self.primeHomeShapes(),
                  let freed = await self.staleOrdinaryPlaceStayCount(release: true) else {
                return CoverageReconciliationOutcome.failed
            }
            return CoverageReconciliationOutcome.committed(resetCount: freed)
        }
        guard outcome.resetCount > 0 else { return outcome }
        _ = await runPipelineStagesWithGates(maxStaysPerCall: nil, gate: gate)
        _ = await generateTitlesStage(maxTripsPerCall: nil, applyGate: gate)
        if lastPipelineMadeChanges {
            await MainActor.run { WidgetCenter.shared.reloadAllTimelines() }
        }
        return outcome
    }

    // MARK: - Routine-place reconciliation

    /// Reconcile routine coverage without home-specific changes: no startedAt backdating for brief visits,
    /// no distanceFromHomeKm recompute because only homes define that field, and no homecoming endDate change
    /// because routine stays are never boundaries in hasHomeStayBetween.
    @discardableResult
    func applyRoutinePlaceChange(
        placeID: UUID,
        gate: PipelineGate = .shared,
        pinnedTripIDs: @escaping @MainActor @Sendable () -> Set<UUID> = { PinnedTripsStorage.shared.pinnedIDs },
        onSettled: (@MainActor @Sendable () -> Void)? = nil
    ) async -> CoverageReconciliationOutcome {
        guard await takeLatchQueued(waiting: {
            logger.debug("Pipeline running; routine-place reconciliation queued.")
        }) else { return .cancelled }
        defer { isRunning = false }

        let outcome = await gate.runReturning(
            touching: [.routinePlace, .stay, .trip]
        ) {
            guard await self.primeHomeShapes() else {
                return CoverageReconciliationOutcome.failed
            }
            let pinned = await pinnedTripIDs()
            return await self.applyRoutinePlaceChangeCore(placeID: placeID, pinnedTripIDs: pinned)
        }
        if outcome.isSettled, let onSettled { await onSettled() }
        let resetCount = outcome.resetCount
        guard resetCount > 0 else { return outcome }
        _ = await runPipelineStagesWithGates(maxStaysPerCall: nil, gate: gate)

        logger.info("Routine-place change: reset \(resetCount) stay(s); re-running pipeline.")
        _ = await generateTitlesStage(
            maxTripsPerCall: nil,
            applyGate: gate)
        if lastPipelineMadeChanges {
            await MainActor.run { WidgetCenter.shared.reloadAllTimelines() }
        }
        return outcome
    }

    /// The deterministic half of `applyRoutinePlaceChange`, split from the
    /// pipeline re-run so tests can drive it without Stage 2.
    /// Caller must hold `isRunning`. Reads are required, as in the Home core.
    internal func applyRoutinePlaceChangeCore(
        placeID: UUID, pinnedTripIDs: Set<UUID> = []
    ) -> CoverageReconciliationOutcome {
        let id = placeID
        let placePredicate = #Predicate<RoutinePlace> { $0.id == id }
        let placeExists: Bool
        do {
            #if DEBUG
            if failRoutineReadForTesting { throw CocoaError(.fileReadUnknown) }
            #endif
            placeExists = try modelContext.fetch(
                FetchDescriptor<RoutinePlace>(predicate: placePredicate)).first != nil
        } catch {
            logger.error("Routine-place change skipped; edited place unreadable: \(error.localizedDescription)")
            return .failed
        }
        guard placeExists else { return .placeMissing }

        guard let allStays = fetchReconciliationStays(orSkip: "Routine-place change") else { return .failed }
        guard !allStays.isEmpty else { return .committed(resetCount: 0) }
        guard let dependencies = fetchHomeAreaDependencies(orSkip: "Routine-place change") else { return .failed }
        let routineRows = dependencies.routinePlaces
        let homeRows = classificationAnchors(of: dependencies)
        let overrides = dependencies.overrides
        guard let curated = curatedTripIDs(
            stays: allStays, pinnedTripIDs: pinnedTripIDs, orSkip: "Routine-place change") else { return .failed }

        let routineRings = routineRows.map {
            RoutineRing(
                latitude: $0.latitude,
                longitude: $0.longitude,
                radiusMeters: $0.radiusMeters,
                startedAt: $0.startedAt,
                endedAt: $0.endedAt
            )
        }
        let homeRings = withShapes(homeRows.map { HomeRing($0) }, overrides: overrides)

        var affectedCompletedTrips: [ObjectIdentifier: Trip] = [:]
        var affectedOpenTrips: [ObjectIdentifier: Trip] = [:]

        func resetStay(_ stay: Stay) {
            if let trip = stay.trip {
                let identity = ObjectIdentifier(trip)
                if trip.isComplete {
                    affectedCompletedTrips[identity] = trip
                } else {
                    affectedOpenTrips[identity] = trip
                }
            }
            stay.category = .unclassified
            stay.trip = nil
            stay.orderInTrip = nil
        }
        func isUsers(_ stay: Stay) -> Bool {
            stay.userOverridden || stay.trip?.userEdited == true
        }
        // As in the Home core: a curated trip keeps a stay the edit covers.
        var spared = Set<UUID>()
        func spares(_ stay: Stay) -> Bool {
            guard let trip = stay.trip, curated.contains(trip.id) else { return false }
            spared.insert(trip.id)
            return true
        }
        // As in the Home core: while the store may be hydrating, a completed
        // trip whose stays do not give every place its stored summary names
        // is left whole, judged before any of its stays is detached.
        var hydrating: Bool?
        var leftWhole: [ObjectIdentifier: Bool] = [:]
        func defers(_ stay: Stay) -> Bool {
            guard let trip = stay.trip, trip.isComplete else { return false }
            let identity = ObjectIdentifier(trip)
            if let judged = leftWhole[identity] { return judged }
            let leaves = !TripTitleStore.mayDeriveSummary(
                holdsNamedStays: TripTitleStore.holdsItsNamedStays(trip), hydrating: &hydrating)
            leftWhole[identity] = leaves
            return leaves
        }
        func matchesRoutineNow(_ stay: Stay) -> Bool {
            Self.matchesRoutine(
                stayStart: stay.startTime,
                latitude: stay.centroidLatitude,
                longitude: stay.centroidLongitude,
                places: routineRings
            )
        }
        func matchesHomeNow(_ stay: Stay) -> Bool {
            Self.matchesHome(
                stayStart: stay.startTime,
                latitude: stay.centroidLatitude,
                longitude: stay.centroidLongitude,
                homes: homeRings
            )
        }

        var resetCount = 0

        // Both loops are deliberately GLOBAL rather than scoped to the changed
        // ring: a coverage change adds matches in one direction and removes
        // them in the other, and using the same predicate `preFilterStays`
        // stamps with is what makes the pair non-oscillating.

        // Stamp direction: a trip stay that now falls inside a routine ring.
        // Home wins in `preFilterStays`, so a home-matching stay is left alone.
        for stay in allStays where stay.category == .destination || stay.category == .transit {
            guard !isUsers(stay) else { continue }
            guard !matchesHomeNow(stay) else { continue }
            if matchesRoutineNow(stay), !spares(stay), !defers(stay) {
                resetStay(stay)
                resetCount += 1
            }
        }

        // Release routine stays no longer covered after a shrink or move.
        for stay in allStays where stay.category == .routine {
            guard !isUsers(stay) else { continue }
            if !matchesRoutineNow(stay), !spares(stay), !defers(stay) {
                resetStay(stay)
                resetCount += 1
            }
        }
        let sparedTrips = markSparedTripsEdited(spared, stays: allStays)

        // See the home-change path: without clearing here, assembly observes
        // only the post-detach membership and can carry a pre-detach title
        // (and every localized derivative) onto that smaller ongoing trip.
        for trip in affectedOpenTrips.values {
            TripTitleStore.invalidateGeneratedTitles(
                for: trip, in: modelContext)
        }

        // Reconcile completed trips the stamp direction emptied. Completed
        // trips are never rebuilt by assembly, so without this a trip whose
        // stays became routine survives as a zero-stay ghost card.
        var deletedGhostTrips = 0
        for trip in affectedCompletedTrips.values {
            let remaining = trip.orderedStays
            guard let first = remaining.first,
                  remaining.contains(where: { $0.category == .destination }) else {
                for stay in remaining {
                    stay.trip = nil
                    stay.orderInTrip = nil
                }
                modelContext.delete(trip)
                deletedGhostTrips += 1
                continue
            }
            trip.startDate = first.startTime
            // endDate deliberately untouched — see the type-level note.
            TripTitleStore.invalidateGeneratedTitles(
                for: trip, in: modelContext)
            // See the home-change path: judged before the detach, never after it.
            guard leftWhole[ObjectIdentifier(trip)] == false else {
                TripTitleStore.oweSummaryRefresh()
                continue
            }
            // See the home-change path: a failed home-place read keeps the debt.
            guard trip.recomputeSummary() else {
                return rollBackUnreadableHomePlaces(unit: "Routine-place change")
            }
        }
        if deletedGhostTrips > 0 {
            logger.info("Routine-place change: deleted \(deletedGhostTrips) fully-absorbed completed trip(s).")
        }
        let leftWholeTrips = leftWhole.values.filter { $0 }.count
        if leftWholeTrips > 0 {
            logger.info("Routine-place change: left \(leftWholeTrips) completed trip(s) whole until hydration settles.")
        }

        guard saveReconciliation(unit: "Routine-place change", sparedTrips: sparedTrips) else { return .failed }
        return leftWholeTrips > 0 ? .deferred(resetCount: resetCount) : .committed(resetCount: resetCount)
    }
}
