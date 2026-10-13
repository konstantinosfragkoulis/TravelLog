//
//  TripClassifier+TemporaryHomeReconciliation.swift
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

    // MARK: - Temporary home reconciliation

    /// A temporary-home reconciliation unit's result. Only `committed`
    /// discharges a pending reconciliation. A row that is gone still commits:
    /// removing a temporary home runs the reverse pass.
    nonisolated enum TemporaryHomeReconciliationOutcome: Sendable, Equatable {
        /// The unit saved (or had nothing to change). `stamped` stays joined
        /// the temporary home, `freed` stays left it and now await the
        /// pipeline, `rebuiltTrips` were detached and reassembled (the ones
        /// the user engaged with archived first), and `protectedTrips` sit
        /// beside a freed stay, or are explicitly kept and hold a stay in its
        /// area, and were kept as they are.
        case committed(stamped: Int, freed: Int, rebuiltTrips: Int, protectedTrips: Int)
        /// Saved like `committed`, but home stays this temporary home stamped
        /// from a newer copy than the one the unit read would have been freed
        /// or handed on, and were left as they are: the debt stays
        /// queued until the newer copy arrives or the unit reissues its own.
        case deferred(stamped: Int, freed: Int, rebuiltTrips: Int, protectedTrips: Int)
        /// Cancelled while queued behind the pipeline; nothing ran.
        case cancelled
        /// A required read, a recovery record or the save failed; the unit rolled back.
        case failed

        var isSettled: Bool {
            if case .committed = self { return true }
            return false
        }

        /// The counts of a unit that saved, deferred or not.
        var counts: (stamped: Int, freed: Int, rebuiltTrips: Int, protectedTrips: Int)? {
            switch self {
            case .committed(let stamped, let freed, let rebuilt, let kept),
                 .deferred(let stamped, let freed, let rebuilt, let kept):
                return (stamped, freed, rebuilt, kept)
            case .cancelled, .failed:
                return nil
            }
        }

        /// The unit saved (or had nothing to change), deferred or not.
        var didCommit: Bool { counts != nil }
    }

    /// What a temporary-home change would do, for the sheet. See `previewTemporaryHomeChange`.
    nonisolated struct TemporaryHomeChangePreview: Sendable, Equatable {
        nonisolated struct TripLine: Sendable, Equatable, Identifiable {
            let id: UUID
            let name: String
            let start: Date
            let end: Date?
            /// Why the trip is kept or split, in `TripInteraction.allCases` order;
            /// empty for a rebuilt trip.
            let reasons: [TripInteraction]
        }

        /// Stays that would become time at the temporary home.
        let staysJoining: Int
        /// Home stays no home would claim any more.
        let staysLeaving: Int
        /// Trips nobody engaged with that would be detached and reassembled
        /// around the temporary home.
        let tripsRebuilt: [TripLine]
        /// Trips the user engaged with that a stay leaving the area would
        /// otherwise merge with their neighbours, and explicitly kept trips the
        /// area covers. They stay as they are.
        let tripsKept: [TripLine]
        /// The earliest start and the latest end among the stays the proposed
        /// area contains, whatever its dates.
        let firstStayInArea: Date?
        let lastStayInArea: Date?
        /// False when no urban centre holds the pin and the area is the 1 km fallback.
        let areaIsCityBoundary: Bool
        /// Completed trips nobody engaged with that sit beside a stay leaving the
        /// temporary home: the pass that follows merges them into a longer trip.
        /// For display; the reconciliation does not read it.
        var tripsMerged: [TripLine] = []
        /// The named time zone most stays in the proposed area carry (the one
        /// with the newest stay when two tie). A live stay is stamped with the
        /// device's zone when it was clustered, which for the last stay before a
        /// flight can be the next place's; an approximated fixed offset has no
        /// "/". Nil when there is none.
        var areaTimeZoneIdentifier: String? = nil
        /// Trips the user engaged with that the area covers: the save archives
        /// each in Removed Trips and splits it around the temporary home.
        var tripsSplit: [TripLine] = []
        /// The first stay in the proposed area after the last qualifying stay
        /// at a real Home that precedes the newest stay there: the likely
        /// arrival. Nil when the area holds no stay.
        var arrivalInArea: Date? = nil
    }

    /// Reconciles history with a temporary home added, edited, ended or removed in one
    /// gated unit (`applyTemporaryHomeChangeCore`) that reads favourites inside it.
    /// `onSettled` runs after its commit, `unpinRetired` drops the split trips'
    /// favourites before the gate lets go, and the unit is acknowledged in
    /// `acknowledgementDirectory` before it lets go too. The follow-up pass runs only when something changed.
    @discardableResult
    func applyTemporaryHomeChange(
        temporaryHomeID: UUID,
        pinnedTripIDs: @escaping @MainActor @Sendable () -> Set<UUID>,
        gate: PipelineGate = .shared,
        unpinRetired: @escaping @MainActor @Sendable (Set<UUID>) -> Void = { ids in
            for id in ids { PinnedTripsStorage.shared.unpin(id) }
        },
        acknowledgementDirectory: URL? = nil,
        onSettled: (@MainActor @Sendable () -> Void)? = nil
    ) async -> TemporaryHomeReconciliationOutcome {
        while isRunning {
            guard !Task.isCancelled else { return .cancelled }
            logger.debug("Pipeline running; temporary-home reconciliation queued.")
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return .cancelled }
        }
        isRunning = true
        defer { isRunning = false }

        // When a unit for this id first left a newer copy's stamps in place.
        let deferredSince = CoverageReconciliationQueue.Acknowledgements
            .load(from: acknowledgementDirectory)[temporaryHomeID]?.deferredSince
        // `.homeAreaOverride` too: a removed temporary home's corrections go in
        // the unit, and the photo rows of a trip it splits move into its archive.
        let outcome = await gate.runReturning(
            touching: [.temporaryHome, .stay, .trip, .homeAreaOverride, .hiddenPhoto, .pinnedPhoto]
        ) {
            // The gate runs a unit whose caller was cancelled while it waited;
            // the core commits whole, so stop here, before anything changes.
            guard !Task.isCancelled else { return TemporaryHomeReconciliationOutcome.cancelled }
            guard await self.primeHomeShapes() else {
                return TemporaryHomeReconciliationOutcome.failed
            }
            // Favorites as they are now, not as they were when this call was queued.
            let pinned = await pinnedTripIDs()
            guard !Task.isCancelled else { return TemporaryHomeReconciliationOutcome.cancelled }
            let outcome = await self.applyTemporaryHomeChangeCore(
                temporaryHomeID: temporaryHomeID, pinnedTripIDs: pinned,
                deferredSince: deferredSince, now: .now)
            // The trips the unit split are gone: their favourites and photo
            // caches go too, after the commit and before the gate lets a Keep
            // as One Trip in, so it can never be undone by them (their archives
            // hold both).
            var retired = Set<UUID>()
            if outcome.counts != nil { retired = await self.temporaryHomeUnitRetiredTripIDs }
            if !retired.isEmpty {
                await MainActor.run {
                    unpinRetired(retired)
                    for id in retired { PhotoService.shared.invalidateCache(for: id) }
                    StoreChangeTracker.shared.bump([.trip, .hiddenPhoto, .pinnedPhoto])
                }
            }
            // Only after the commit, and only what this unit processed: a later
            // change is the next drain's to discover. Inside the unit, so a
            // Delete All Data cannot clear the file before this lands.
            if outcome.didCommit, let acknowledgement = await self.temporaryHomeUnitAcknowledgement,
               acknowledgement.id == temporaryHomeID {
                CoverageReconciliationQueue.Acknowledgements.record(
                    temporaryHomeID, digest: acknowledgement.digest,
                    deferred: acknowledgement.deferred, at: .now, in: acknowledgementDirectory)
            }
            return outcome
        }
        #if DEBUG
        await TemporaryHomeTestHook.afterUnit?()
        #endif
        if outcome.isSettled, let onSettled { await onSettled() }
        guard let (stamped, freed, rebuilt, _) = outcome.counts else { return outcome }
        let staysMoved = stamped + freed > 0
        let clearedTitle = temporaryHomeUnitClearedTitle
        // A date edit can change a confidence verdict without moving a stay: the
        // invariant check sees it through the suppression digest. A store with no
        // temporary home at all is not this unit's to assemble.
        let followUp = staysMoved
            || (temporaryHomeUnitFoundOne && assemblyInvariantViolated())
        if followUp {
            _ = await runPipelineStagesWithGates(maxStaysPerCall: nil, gate: gate)
            logger.info("Temporary home change: stamped \(stamped) and freed \(freed) stay(s); re-ran pipeline.")
        }
        // A title the unit kept needs no model; one it cleared, and a trip it
        // rebuilt, is named now.
        if staysMoved || rebuilt > 0 || clearedTitle {
            _ = await generateTitlesStage(
                maxTripsPerCall: nil,
                sampling: .greedy,
                applyGate: gate)
        }
        guard followUp || rebuilt > 0 || clearedTitle else { return outcome }
        // The unit itself changed the store, whatever the follow-up pass found.
        await MainActor.run { WidgetCenter.shared.reloadAllTimelines() }
        return outcome
    }

    /// The synchronous half of `applyTemporaryHomeChange`; the caller holds `isRunning`
    /// and primed shapes and orbits. Every read precedes the first mutation and the unit
    /// commits once: any failure rolls it back whole, and a replay changes nothing. It
    /// acts under `StampAuthority` (a newer copy's stamps make it `deferred`); past
    /// `deferralBound` since `deferredSince` it reissues the declaration above every
    /// revision it observes and acts on that.
    internal func applyTemporaryHomeChangeCore(
        temporaryHomeID: UUID, pinnedTripIDs: Set<UUID>,
        deferredSince: Date? = nil, now: Date = .now
    ) -> TemporaryHomeReconciliationOutcome {
        let unit = "Temporary home change"
        temporaryHomeUnitAcknowledgement = nil
        // Read by the wrapper after any outcome: only a commit sets it.
        temporaryHomeUnitRetiredTripIDs = []
        guard let inputs = fetchTemporaryHomeChangeInputs(orSkip: unit) else { return .failed }

        // Rings as they stand after the edit. A removed temporary home has no
        // ring, so only the reverse pass applies, and the corrections taught
        // to a removed one are withdrawn. An id with neither a row nor a
        // removal has not arrived on this device: it frees and withdraws nothing.
        let rings = withShapes(inputs.anchors.map { Self.HomeRing($0) }, overrides: inputs.overrides)
        let target = rings.first(where: { $0.isTemporary && $0.homeID == temporaryHomeID })
        let withdrawn = inputs.overrides.filter { row in
            row.homeID.map { inputs.removedIDs.contains($0) } ?? false
        }
        let unitIsLive = inputs.anchors.contains { $0.isTemporary && $0.id == temporaryHomeID }
        var revisions = inputs.revisions
        let makePlan = { (revision: Int?) in
            Self.temporaryHomeChangePlan(
                target: target, rings: rings, unitID: temporaryHomeID,
                unitIsLive: unitIsLive, unitRevision: revision,
                removedIDs: inputs.removedIDs, routineRings: inputs.routineRings,
                stays: inputs.stays, trips: inputs.trips,
                visitBackedStayIDs: inputs.visitBackedStayIDs,
                pinnedTripIDs: pinnedTripIDs, hiddenTripIDs: inputs.hiddenTripIDs,
                pinnedPhotoTripIDs: inputs.pinnedPhotoTripIDs,
                explicitlyKeptTripIDs: inputs.explicitlyKeptTripIDs)
        }
        var plan = makePlan(unitIsLive ? revisions[temporaryHomeID] : nil)
        // The losing branch: stamps of a newer copy that never won have waited
        // the whole bound. The copy every reader resolves to is written again
        // on every row above each revision seen, its place and dates
        // unchanged, so they are acted on here and on every device.
        var reissued = false
        if unitIsLive, !plan.deferred.isEmpty, let deferredSince,
           now.timeIntervalSince(deferredSince)
            >= CoverageReconciliationQueue.Acknowledgements.deferralBound {
            let rows = inputs.declarations.filter { $0.id == temporaryHomeID }
            if let winner = HomeAnchors.collapsingTwins(rows).first {
                let stamped = inputs.stays.compactMap {
                    $0.temporaryHomeID == temporaryHomeID ? $0.temporaryHomeRevision : nil
                }
                let revision = max(
                    TemporaryHome.nextCoverageRevision(of: rows), (stamped.max() ?? 0) + 1)
                Self.reissue(rows, as: winner, revision: revision, now: now)
                revisions[temporaryHomeID] = revision
                plan = makePlan(revision)
                reissued = true
            }
        }
        let counts = (
            stamped: plan.candidates.count, freed: plan.stale.count,
            rebuilt: plan.affectedTrips.count, kept: plan.protectedTrips.count)
        let committed: TemporaryHomeReconciliationOutcome = plan.deferred.isEmpty
            ? .committed(stamped: counts.stamped, freed: counts.freed,
                         rebuiltTrips: counts.rebuilt, protectedTrips: counts.kept)
            : .deferred(stamped: counts.stamped, freed: counts.freed,
                        rebuiltTrips: counts.rebuilt, protectedTrips: counts.kept)
        // What this unit processed and left, for its wrapper to acknowledge
        // once it committed: read from its own rows as it saved them, the
        // trips its assembly made included.
        func acknowledge() {
            guard unitIsLive, let trips = try? modelContext.fetch(FetchDescriptor<Trip>()),
                  let digest = Self.temporaryHomeDigests(
                      rows: inputs.declarations, rings: rings, stays: inputs.stays, trips: trips,
                      pinnedTripIDs: pinnedTripIDs, hiddenTripIDs: inputs.hiddenTripIDs,
                      pinnedPhotoTripIDs: inputs.pinnedPhotoTripIDs,
                      visitBackedStayIDs: inputs.visitBackedStayIDs)[temporaryHomeID]
            else { return }
            temporaryHomeUnitAcknowledgement = (temporaryHomeID, digest, !plan.deferred.isEmpty)
        }
        // Stored names are refreshed only where a temporary home exists or
        // existed: a debt whose row never saved changes nothing.
        let refreshesNames = !inputs.removedIDs.isEmpty
            || inputs.anchors.contains { $0.isTemporary }
        temporaryHomeUnitClearedTitle = false
        temporaryHomeUnitFoundOne = refreshesNames

        func rollBack(_ reason: String) -> TemporaryHomeReconciliationOutcome {
            modelContext.rollback()
            // Never serve a home-place snapshot built from rolled-back rows.
            TripTitleStore.invalidateHomePlaceIndex()
            hasRunBackHalfSinceLaunch = false
            logger.error("\(unit, privacy: .public) rolled back; \(reason, privacy: .public)")
            return .failed
        }

        // Before anything changes: every trip the user engaged with that the
        // covering splits is archived whole, its stays with the categories and
        // settings they have now. Its id is retired: no piece takes it.
        // Copies of one stay set differently cannot be one archived stay: the
        // unit fails before anything is deleted.
        guard var splitRecords = makeSplitRecords(
            plan.splitTrips.map(\.trip.id), rows: plan.affectedTrips,
            temporaryHomeID: temporaryHomeID, pinnedTripIDs: pinnedTripIDs) else {
            return rollBack("two copies of a stay on a trip it splits are set differently")
        }
        let retiredIDs = Set(splitRecords.map(\.id))

        // Before any stay moves: every trip the user engaged with that the
        // change touches outside the covering, open or completed, becomes
        // edited, so assembly's exemption holds it whole with its members and
        // id in this unit and in every later pass. The worker's save marked the
        // ones its preview listed; these inputs are current, so this mark is the
        // one that counts. `keptByTemporaryHome` says the mark is this feature's.
        // Nothing here ever releases it: a favorite or photo choice that is
        // gone is not the user's consent. A covering unit consumes the mark
        // instead: the trip is split, and its archive holds the edit as the
        // user left it.
        let kept = plan.protectedTrips.map(\.trip)
        let exposed = plan.protectedTrips.filter(\.exposed).map(\.trip)
        var marked = false
        for trip in kept where !trip.userEdited {
            trip.userEdited = true
            trip.keptByTemporaryHome = true
            marked = true
        }

        // The pass state the classification below and the back half read,
        // set as a pipeline pass sets it.
        visitBackedStayIDs = inputs.visitBackedStayIDs
        fmClassifiedStayIDs = []
        heuristicClassifiedStayIDs = []
        lastPipelineMadeChanges = false
        summaryHomePlacesUnreadable = false

        // A kept trip's members stay its own. One a pass reset and has not
        // judged yet, or one the pre-filter stamped home while still linked,
        // is judged again by the duration rules and the heuristics on the
        // fresh timeline, without the pre-filter: inside the base it would
        // only come back home, inside a trip assembly never regroups. So are
        // the members of the trips kept earlier (`keptEarlierTrips`). A home
        // member a declaration stamped is judged only under the unit's
        // authority unless an explicit keep holds its trip (`settledMembers`).
        let unsettled = plan.settledMembers
        if !unsettled.isEmpty {
            for stay in unsettled { stay.category = .unclassified }
            let settled = resolveDeterministicOutcomes(unsettled)
            registerStage2aProvenance(settled.resolved, asFM: false)
            _ = classifyWithHeuristics(
                stays: settled.ambiguous, ordered: inputs.stays.sorted(by: Self.classificationOrder))
            guard unsettled.allSatisfy({ $0.category != .unclassified }) else {
                return rollBack("a kept trip's stay was left unclassified")
            }
        }

        for row in withdrawn { modelContext.delete(row) }
        // A covered trip is rebuilt even when none of its stays changes category.
        guard !plan.candidates.isEmpty || !plan.stale.isEmpty || !plan.affectedTrips.isEmpty else {
            // No stay moves; the marks, the settled members, the withdrawn
            // corrections, the handoffs, a reissue and the names the new dates
            // or place change still commit.
            Self.applyHandoffs(plan.handoffs, revisions: revisions)
            var renamed = false
            if refreshesNames {
                guard let refresh = refreshStoredTripNames() else {
                    modelContext.rollback()
                    TripTitleStore.invalidateHomePlaceIndex()
                    logger.error("\(unit, privacy: .public) rolled back; a trip's stored names could not be read.")
                    return .failed
                }
                renamed = refresh.wrote
                temporaryHomeUnitClearedTitle = refresh.clearedTitle
            }
            guard marked || !unsettled.isEmpty || !withdrawn.isEmpty
                    || !plan.handoffs.isEmpty || renamed || reissued else {
                acknowledge()
                return committed
            }
            guard saveReconciliation(unit: unit) else { return .failed }
            acknowledge()
            return committed
        }

        // Suppressed stays were excused against the roster before the edit;
        // the next assembly judges them against this one.
        gateSuppressedStayFingerprints = [:]

        // Before any category changes: snapshot every affected completed trip with
        // its original categories. A record is kept only for a trip no rebuilt trip
        // carries on (absorbed whole, or left with outings the gate sets aside),
        // parked as healing parks one. A split trip has its archive.
        let recoverable = plan.affectedTrips
            .filter { $0.isComplete && !retiredIDs.contains($0.id) }
            .map { makeDissolvedRecord(for: $0, dissolvedByDemotion: false) }

        let windows = inputs.anchors.map { StayClusterer.HomeWindow($0) }
        // Reverse: home stays no ring claims any more await the pipeline. One a
        // withdrawn correction had stamped loses that stamp, as `unHomeStays` clears it.
        for stay in plan.stale {
            stay.category = .unclassified
            if stay.userOverridden { stay.userOverridden = false }
            stay.distanceFromHomeKm = StayClusterer.closestHomeDistanceKm(
                latitude: stay.centroidLatitude, longitude: stay.centroidLongitude,
                atTime: stay.startTime, homes: windows)
        }
        // Forward: reset each candidate with its trip link intact, then stamp it
        // through the ordinary pre-filter. One that does not come back home means
        // the plan and the pre-filter disagree. No candidate is a stay the user set.
        if !plan.candidates.isEmpty {
            for stay in plan.candidates {
                stay.category = .unclassified
                stay.distanceFromHomeKm = StayClusterer.closestHomeDistanceKm(
                    latitude: stay.centroidLatitude, longitude: stay.centroidLongitude,
                    atTime: stay.startTime, homes: windows)
            }
            guard preFilterStays(plan.candidates) == plan.candidates.count,
                  plan.candidates.allSatisfy({ $0.category == .home }) else {
                return rollBack("a stay in the temporary home's area was not stamped home")
            }
        }
        // The affected trips' other members were measured and judged inside the
        // old trip. Measure them from the homes as they are now, then judge them
        // again as stranded stays are judged: the pre-filter, the duration rules,
        // the heuristics on the fresh timeline. Assembly groups only classified
        // stays, so one left unclassified fails the unit. A home stay the unit
        // may not release (`StampAuthority`) keeps its category and pair, as
        // the plan projected.
        let stamped = Set(plan.candidates.map(\.persistentModelID))
        let remnants = plan.affectedTrips.flatMap { $0.stays ?? [] }
            .filter { !stamped.contains($0.persistentModelID) }
        for stay in remnants {
            let km = StayClusterer.closestHomeDistanceKm(
                latitude: stay.centroidLatitude, longitude: stay.centroidLongitude,
                atTime: stay.startTime, homes: windows)
            if abs(km - stay.distanceFromHomeKm) > 0.001 { stay.distanceFromHomeKm = km }
        }
        let authority = StampAuthority(
            unitID: temporaryHomeID, unitIsLive: unitIsLive,
            unitRevision: unitIsLive ? revisions[temporaryHomeID] : nil,
            removedIDs: inputs.removedIDs)
        let rejudged = remnants.filter { !$0.userOverridden && authority.mayRejudge($0) }
        if !rejudged.isEmpty {
            for stay in rejudged { stay.category = .unclassified }
            guard preFilterStays(rejudged) >= 0 else {
                return rollBack("the pre-filter could not read its dependencies")
            }
            let settled = resolveDeterministicOutcomes(rejudged)
            registerStage2aProvenance(settled.resolved, asFM: false)
            _ = classifyWithHeuristics(
                stays: settled.ambiguous, ordered: inputs.stays.sorted(by: Self.classificationOrder))
            guard rejudged.allSatisfy({ $0.category != .unclassified }) else {
                return rollBack("a rebuilt trip's stay was left unclassified")
            }
        }
        // A kept trip the stays leaving expose was measured from the home it
        // left, which may have been this temporary home. Measure its members
        // again as assembly measures a trip: from the home that claims the last
        // home stay before it, now that the freed stays are no longer home.
        // The same goes for a kept trip that a stay stamped above now separates
        // from the freed ones. Nothing else of a kept trip changes, and one a
        // forward declaration keeps is not touched: it left a real Home.
        let leftAFreedHome = exposed + plan.remeasuredTrips
        if !leftAFreedHome.isEmpty {
            let homeStays = inputs.stays.filter { $0.category == .home }
            for trip in leftAFreedHome {
                stampDistancesFromDepartureHome(
                    trip.orderedStays, homeStays: homeStays, homeRings: rings)
            }
        }
        TripTitleStore.invalidateHomePlaceIndex()

        // Detach the affected trips. Each id follows the largest surviving
        // overlap after assembly; one that nothing claims stays with its
        // recovery record. Same-id twins are one identity: the union of their
        // stays, the earliest start. A split trip's id competes for nothing,
        // and its hidden and pinned photo rows move into its archive.
        var identities: [UUID: (stayIDs: Set<UUID>, startDate: Date)] = [:]
        var retiredStayIDs = Set<UUID>()
        for trip in plan.affectedTrips {
            let members = trip.stays ?? []
            let stayIDs = Set(members.map(\.id))
            if retiredIDs.contains(trip.id) {
                retiredStayIDs.formUnion(stayIDs)
            } else if !stayIDs.isEmpty {
                let twin = identities[trip.id]
                identities[trip.id] = (
                    stayIDs.union(twin?.stayIDs ?? []),
                    min(trip.startDate, twin?.startDate ?? trip.startDate))
            }
            for stay in members {
                stay.trip = nil
                stay.orderInTrip = nil
            }
            modelContext.delete(trip)
        }
        do {
            for index in splitRecords.indices {
                let rows = try deletePhotoAnnotationRows(keyedTo: splitRecords[index].id)
                if !rows.isEmpty { splitRecords[index].photoAnnotations = rows }
            }
        } catch {
            return rollBack(error.localizedDescription)
        }

        // The back half as a pipeline pass runs it (sanity, orbits, assembly,
        // closure, summary check), leaving the commit to this unit. Its
        // identities wait for the one arbitration below, and a split trip's
        // stays join no trip that already exists: their pieces are new.
        lastPipelineMadeChanges = true
        deferredAssemblyIdentities = DeferredAssemblyIdentities(retiredStayIDs: retiredStayIDs)
        defer { deferredAssemblyIdentities = nil }
        let backHalfCompleted: Bool
        let parked: [DissolvedTripRecord]
        do {
            backHalfCompleted = try assembleClassificationResults(
                classified: 0, needsPublication: true, completingRebuild: true).backHalfCompleted
            let assembled = deferredAssemblyIdentities ?? DeferredAssemblyIdentities()
            let constituents = identities.map {
                (id: $0.key, stayIDs: $0.value.stayIDs, startDate: $0.value.startDate)
            } + assembled.constituents
            // Provenance is assembly's own: every remaining member was judged
            // again above, so a detached trip's flag describes none of them.
            let carriedOn = Self.arbitrateTemporaryHomeIdentities(
                outputs: assembled.outputs.filter { !$0.isDeleted },
                constituents: constituents.filter { !retiredIDs.contains($0.id) },
                retiredIDs: retiredIDs, retiredStayIDs: retiredStayIDs)
            parked = recoverable.filter { !carriedOn.contains($0.id) }
        } catch {
            return rollBack(error.localizedDescription)
        }
        // Still home, now another temporary home's: assembly left them alone.
        Self.applyHandoffs(plan.handoffs, revisions: revisions)
        // The rebuilt trips were just named from these homes; the kept,
        // remeasured and merely overlapping ones were not.
        if refreshesNames {
            guard let refresh = refreshStoredTripNames() else {
                return rollBack("a trip's stored names could not be read")
            }
            temporaryHomeUnitClearedTitle = refresh.clearedTitle
        }
        // Each archive takes the split as it now stands, then every record is
        // durable before the deleting save, like healing's records.
        let existingTripIDs = Set(inputs.trips.map(\.id))
        for index in splitRecords.indices {
            Self.recordPostSplitState(
                in: &splitRecords[index], stays: inputs.stays, existingTripIDs: existingTripIDs)
            inheritHiddenPhotos(in: &splitRecords[index])
        }
        Self.markSharedInheritedHiddenPhotos(in: &splitRecords)
        do {
            if !parked.isEmpty || !splitRecords.isEmpty {
                try persistDissolvedRecords(parked + splitRecords)
            }
        } catch {
            return rollBack(error.localizedDescription)
        }

        guard saveReconciliation(unit: unit) else {
            hasRunBackHalfSinceLaunch = false
            return .failed
        }
        // The launch latch requires the unit's commit.
        if backHalfCompleted { hasRunBackHalfSinceLaunch = true }
        temporaryHomeUnitRetiredTripIDs = retiredIDs
        // The split committed: its archives say so, so a later split of the
        // same id keeps them as they are. One whose mark fails stays prepared,
        // which only a new split of its trip, gone now, would replace.
        if !splitRecords.isEmpty {
            try? persistDissolvedRecords(splitRecords.map {
                var record = $0
                record.splitCommitted = true
                return record
            })
        }
        // The sink made the records durable before the save; healing's drain
        // releases them. Nothing appends them again: Keep as One Trip or
        // Forget removes one from the queue, and nothing may bring it back.
        parkedDissolvedTrips.append(contentsOf: parked)
        acknowledge()
        return committed
    }

    /// The constituents and outputs of an assembly that runs inside a
    /// temporary-home unit, which arbitrates their identities itself.
    struct DeferredAssemblyIdentities {
        /// The stays of the trips the unit split. Assembly adopts none of
        /// them into a trip it leaves standing: they go to new pieces.
        var retiredStayIDs = Set<UUID>()
        /// Every trip assembly detached: the open ones before regrouping, the
        /// completed ones the pool reached.
        var constituents: [(id: UUID, stayIDs: Set<UUID>, startDate: Date)] = []
        /// Every trip assembly gave a group, the reused open row included.
        var outputs: [Trip] = []
    }

    /// One identity arbitration for a temporary-home unit. Every
    /// constituent (the trips the unit detached and the ones its assembly
    /// detached) is ranked by its membership surviving in the outputs, then
    /// as `identityClaims` ranks, and claims the output it overlaps most, one
    /// id per output. An output holding a member of a split trip is a fresh
    /// piece that no id claims. An output nobody claims keeps its own id
    /// unless another output took it or it is a constituent's that cannot
    /// stand, and then takes a fresh one. Returns the ids carried on.
    private static func arbitrateTemporaryHomeIdentities(
        outputs: [Trip],
        constituents: [(id: UUID, stayIDs: Set<UUID>, startDate: Date)],
        retiredIDs: Set<UUID>, retiredStayIDs: Set<UUID>
    ) -> Set<UUID> {
        var merged: [UUID: (stayIDs: Set<UUID>, startDate: Date)] = [:]
        for constituent in constituents {
            let twin = merged[constituent.id]
            merged[constituent.id] = (
                constituent.stayIDs.union(twin?.stayIDs ?? []),
                min(constituent.startDate, twin?.startDate ?? constituent.startDate))
        }
        let members = outputs.map { Set(($0.stays ?? []).map(\.id)) }
        let claimable = outputs.indices.filter { members[$0].isDisjoint(with: retiredStayIDs) }
        let surviving = claimable.reduce(into: Set<UUID>()) { $0.formUnion(members[$1]) }
        // Read before any output takes a new id: claims are keyed by the ids
        // the outputs hold now, which are distinct.
        let current = outputs.map(\.id)
        let claims = identityClaims(
            snapshots: merged.map {
                (id: $0.key, stayIDs: $0.value.stayIDs.intersection(surviving),
                 startDate: $0.value.startDate)
            },
            rebuilt: claimable.map {
                (id: current[$0], stayIDs: members[$0], startDate: outputs[$0].startDate)
            })
        let carriedOn = Set(claims.values)
        let contested = Set(merged.keys).union(retiredIDs)
        let claimableSet = Set(claimable)
        for (index, output) in outputs.enumerated() {
            if let id = claims[current[index]] {
                if output.id != id { output.id = id }
            } else if contested.contains(current[index]),
                      carriedOn.contains(current[index]) || retiredIDs.contains(current[index])
                        || !claimableSet.contains(index) {
                output.id = UUID()
            }
        }
        return carriedOn
    }

    /// What `applyTemporaryHomeChange` would do if `draft` were the saved temporary
    /// home (or, with `removing`, if its id were removed). Reads the same tables and
    /// computes the same sets as the core and mutates nothing. Nil when a required
    /// read fails.
    func previewTemporaryHomeChange(
        draft: HomeAnchor, removing: Bool, pinnedTripIDs: Set<UUID>
    ) async -> TemporaryHomeChangePreview? {
        guard await primeHomeShapes() else { return nil }
        // The draft's seed, through the provider `primeHomeShapes` uses.
        let key = Self.shapeKey(draft.latitude, draft.longitude)
        if resolvedHomeShapes[key] == nil {
            let shape = await HomeShapeProvider.shared.shape(
                latitude: draft.latitude, longitude: draft.longitude)
            resolvedHomeShapes[key] = shape
        }
        guard let inputs = fetchTemporaryHomeChangeInputs(orSkip: "Temporary home preview") else {
            return nil
        }
        // The stored anchors with the draft substituted, added or removed, in
        // the order the unit reads them, so both name the same owners.
        var anchors = inputs.anchors.filter { !($0.isTemporary && $0.id == draft.id) }
        if !removing { anchors.append(draft) }
        let rings = withShapes(
            Self.canonicalAnchorOrder(anchors).map { Self.HomeRing($0) }, overrides: inputs.overrides)
        let target = removing
            ? nil : rings.first(where: { $0.isTemporary && $0.homeID == draft.id })
        // After a removal the unit reads the id among the removed ones. An
        // edit or End acts on the revision the save writes.
        let plan = Self.temporaryHomeChangePlan(
            target: target, rings: rings, unitID: draft.id, unitIsLive: !removing,
            unitRevision: TemporaryHome.nextCoverageRevision(
                of: inputs.declarations.filter { $0.id == draft.id }),
            removedIDs: removing ? inputs.removedIDs.union([draft.id]) : inputs.removedIDs,
            routineRings: inputs.routineRings,
            stays: inputs.stays, trips: inputs.trips,
            visitBackedStayIDs: inputs.visitBackedStayIDs,
            pinnedTripIDs: pinnedTripIDs, hiddenTripIDs: inputs.hiddenTripIDs,
            pinnedPhotoTripIDs: inputs.pinnedPhotoTripIDs,
            explicitlyKeptTripIDs: inputs.explicitlyKeptTripIDs)

        var inArea: [Stay] = []
        if let membership = target?.membership {
            inArea = inputs.stays.filter {
                membership.contains(latitude: $0.centroidLatitude,
                                    longitude: $0.centroidLongitude, at: $0.startTime)
            }
        }
        var areaIsCityBoundary = false
        if let shape = resolvedHomeShapes[key], case .urbanCentre = shape.seed {
            areaIsCityBoundary = true
        }
        func line(_ trip: Trip) -> TemporaryHomeChangePreview.TripLine {
            TemporaryHomeChangePreview.TripLine(
                id: trip.id, name: trip.displayName, start: trip.startDate,
                end: trip.endDate, reasons: [])
        }
        var zoneTally: [String: (count: Int, newest: Date)] = [:]
        for stay in inArea {
            guard let zone = stay.timeZoneIdentifier, zone.contains("/") else { continue }
            let tally = zoneTally[zone]
            zoneTally[zone] = (
                (tally?.count ?? 0) + 1, max(tally?.newest ?? stay.startTime, stay.startTime))
        }
        let areaTimeZoneIdentifier = zoneTally.max { a, b in
            (a.value.count, a.value.newest, a.key) < (b.value.count, b.value.newest, b.key)
        }?.key
        // The arrival: the first stay in the area after the last qualifying
        // stay at a real Home before the newest one there, so an earlier
        // holiday in the same city is not taken for it.
        var arrivalInArea: Date?
        if let newest = inArea.map(\.startTime).max() {
            let lastRealHome = inputs.stays.filter { stay in
                stay.category == .home && stay.temporaryHomeID == nil
                    && stay.startTime < newest
                    && Self.isQualifyingHomeBoundary(
                        category: .home, source: stay.source,
                        startTime: stay.startTime, endTime: stay.endTime,
                        pingCount: stay.pingCount,
                        hasVisit: inputs.visitBackedStayIDs.contains(stay.id))
            }.map(\.startTime).max()
            arrivalInArea = inArea.map(\.startTime)
                .filter { start in lastRealHome.map { start > $0 } ?? true }.min()
        }
        let splitIDs = Set(plan.splitTrips.map(\.trip.id))
        var rebuiltLines: [TemporaryHomeChangePreview.TripLine] = []
        for trip in plan.affectedTrips where !splitIDs.contains(trip.id) {
            rebuiltLines.append(line(trip))
        }
        var preview = TemporaryHomeChangePreview(
            staysJoining: plan.candidates.count,
            staysLeaving: plan.stale.count,
            tripsRebuilt: rebuiltLines,
            tripsKept: plan.protectedTrips.map { kept in
                TemporaryHomeChangePreview.TripLine(
                    id: kept.trip.id, name: kept.trip.displayName,
                    start: kept.trip.startDate, end: kept.trip.endDate,
                    reasons: TripInteraction.allCases.filter { kept.reasons.contains($0) })
            },
            firstStayInArea: inArea.map(\.startTime).min(),
            lastStayInArea: inArea.map(\.endTime).max(),
            areaIsCityBoundary: areaIsCityBoundary,
            tripsMerged: plan.mergedTrips.map(line),
            areaTimeZoneIdentifier: areaTimeZoneIdentifier)
        preview.tripsSplit = plan.splitTrips.map { split in
            TemporaryHomeChangePreview.TripLine(
                id: split.trip.id, name: split.trip.displayName,
                start: split.trip.startDate, end: split.trip.endDate,
                reasons: TripInteraction.allCases.filter { split.reasons.contains($0) })
        }
        preview.arrivalInArea = arrivalInArea
        return preview
    }

    /// Every table a temporary-home change reads before it mutates or previews.
    /// Nil when one is unreadable: a failed read is not absence. `removedIDs` are
    /// the ids of every raw temporary-home row with a removal date, read past the
    /// twin collapse, which drops them from `anchors`. `explicitlyKeptTripIDs` is
    /// the union of the kept trips of every row of every live declaration.
    /// `declarations` are every raw row, `revisions` each live id's collapsed
    /// `coverageRevision`.
    private func fetchTemporaryHomeChangeInputs(orSkip unit: String) -> (
        anchors: [HomeAnchor], removedIDs: Set<UUID>, overrides: [HomeAreaOverride],
        routineRings: [RoutineRing], stays: [Stay], trips: [Trip],
        visitBackedStayIDs: Set<UUID>, hiddenTripIDs: Set<UUID>, pinnedPhotoTripIDs: Set<UUID>,
        explicitlyKeptTripIDs: Set<UUID>, declarations: [TemporaryHome], revisions: [UUID: Int]
    )? {
        guard let stays = fetchReconciliationStays(orSkip: unit) else { return nil }
        do {
            let anchors = try fetchRequiredAnchors()
            let declarations = try modelContext.fetch(FetchDescriptor<TemporaryHome>())
            let removed = declarations.filter { $0.removedAt != nil }
            let removedIDs = Set(removed.map(\.id))
            let explicitlyKept = TemporaryHome.keptTripIDs(
                of: declarations.filter { !removedIDs.contains($0.id) })
            let overrides = try modelContext.fetch(FetchDescriptor<HomeAreaOverride>())
            // The pre-filter's routine rings, as `preFilterStays` builds them.
            let routineRings = try fetchRequiredRoutinePlaces().map {
                RoutineRing(latitude: $0.latitude, longitude: $0.longitude,
                            radiusMeters: $0.radiusMeters, startedAt: $0.startedAt,
                            endedAt: $0.endedAt)
            }
            let trips = try modelContext.fetch(FetchDescriptor<Trip>())
            let visitBacked = try fetchVisitBackedStayIDs()
            let hidden = try modelContext.fetch(FetchDescriptor<HiddenPhoto>())
            let pinned = try modelContext.fetch(FetchDescriptor<PinnedPhoto>())
            return (anchors: anchors, removedIDs: removedIDs, overrides: overrides,
                    routineRings: routineRings,
                    stays: stays, trips: trips, visitBackedStayIDs: visitBacked,
                    hiddenTripIDs: Set(hidden.map(\.tripID)),
                    pinnedPhotoTripIDs: Set(pinned.map(\.tripID)),
                    explicitlyKeptTripIDs: explicitlyKept,
                    declarations: declarations,
                    revisions: Self.coverageRevisions(of: declarations))
        } catch {
            logger.error("\(unit, privacy: .public) skipped; dependencies unreadable: \(error.localizedDescription)")
            return nil
        }
    }

    /// What `refreshStoredTripNames` wrote.
    private struct StoredNameRefresh {
        var wrote = false
        /// A generated title was cleared for Stage 5 to write again.
        var clearedTitle = false
    }

    /// Brings every trip's stored names up to date with the homes and
    /// categories as a temporary-home unit leaves them, inside the unit and
    /// before its save. A summary is rewritten when it differs from what the
    /// trip's stays give now; a generated title is cleared only when the title
    /// policy rejects it for the inputs now, so a changed summary alone keeps
    /// it. A trip whose stored summary names a place none of its own stays
    /// give was built from stays this device does not hold yet: it is left
    /// whole. Narratives, country codes, source, custom names and spellings
    /// are never written. Nil when a read failed, which fails the unit.
    private func refreshStoredTripNames() -> StoredNameRefresh? {
        // Every read below uses one index built from this unit's context, its
        // unsaved writes included: the shared cache could be refilled by
        // another context with the rows from before them.
        TripTitleStore.invalidateHomePlaceIndex()
        let snapshot: TripTitleStore.HomePlaceIndex.Snapshot
        do {
            snapshot = try TripTitleStore.HomePlaceIndex.uncached(for: modelContext)
        } catch {
            return nil
        }
        return TripTitleStore.HomePlaceIndex.$pinned.withValue(snapshot) {
            refreshStoredTripNamesWithPinnedIndex()
        }
    }

    private func refreshStoredTripNamesWithPinnedIndex() -> StoredNameRefresh? {
        let trips: [Trip]
        do {
            trips = try modelContext.fetch(FetchDescriptor<Trip>())
        } catch {
            return nil
        }
        // Trips with a spent title budget, to compute a shape only where it can matter.
        let exhaustedTripIDs = Set(persistentTitleFailures.compactMap {
            $0.split(separator: "|").first.map(String.init)
        })
        var activeHomes: [CanonicalTitleShape.HomeInput]?
        var refresh = StoredNameRefresh()
        for trip in trips where !trip.isDeleted {
            // Every attached stay's name: a member this unit settled as transit
            // is still the trip's own, not a sign of one missing on this device.
            let own = Set((trip.stays ?? []).flatMap {
                Trip.summaryComponents($0.placeGroupName ?? Trip.unknownDestinationSentinel)
            })
            guard Set(Trip.summaryComponents(trip.destinationSummary)).isSubset(of: own) else {
                continue
            }
            guard let names = trip.summaryNames() else { return nil }
            let summary = names.joined(separator: ", ")
            if trip.destinationSummary != summary {
                trip.destinationSummary = summary
                refresh.wrote = true
            }

            let title = TripTitleStore.normalized(trip.aiGeneratedTitle)
            let generates = trip.customName?.isEmpty != false && !trip.orderedStays.isEmpty
            let mayInstallFallback = generates && exhaustedTripIDs.contains(trip.id.uuidString)
            guard title != nil || mayInstallFallback else { continue }
            guard let homePlaces = try? homePlaceNames(for: trip) else { return nil }
            var cleared = false
            if let title {
                // Judged as the launch pass judges it: a retired spelling counts
                // as its repair, which is not written here.
                let checked = Self.legacyTitleSpellingRepair(title, for: trip) ?? title
                guard titleValidationFailure(
                    checked, for: trip, homePlaceNames: homePlaces) != nil else { continue }
                TripTitleStore.invalidateGeneratedTitles(for: trip, in: modelContext)
                refresh.wrote = true
                cleared = true
            }
            // Stage 5 skips a shape whose retry budget is spent, so an untitled
            // trip back at that shape (an edit reverted) gets the fallback it
            // was given then, without another model attempt.
            if mayInstallFallback {
                if activeHomes == nil {
                    guard let read = try? fetchCanonicalActiveHomeInputs() else { return nil }
                    activeHomes = read
                }
                let shape = canonicalTitleShape(
                    for: trip, activeHomes: activeHomes ?? [], homePlaceNames: homePlaces)
                if persistentTitleFailures.contains(titleFailureKey(for: shape)) {
                    if installFallbackTitle(for: trip, homePlaceNames: homePlaces) != nil {
                        refresh.wrote = true
                    }
                    continue
                }
            }
            if cleared, generates { refresh.clearedTitle = true }
        }
        return refresh
    }
}
