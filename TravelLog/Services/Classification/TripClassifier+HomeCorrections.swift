//
//  TripClassifier+HomeCorrections.swift
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

    // MARK: - Correction channel

    /// One gate-suppressed excursion, shaped for the "Near-home activity"
    /// review list. Value snapshot — the view must never hold live models.
    nonisolated struct SuppressedGroup: Sendable, Identifiable {
        let id: UUID                 // first member stay's id
        let stayIDs: [UUID]
        let start: Date
        let end: Date
        let placeName: String?
        let dwellHours: Double
        let maxDistanceKm: Double
    }

    /// The gate's tripless residue, reconstructed as the groups the assembly
    /// saw: tripless non-userOverridden `.destination` stays, split exactly
    /// where assembly splits — at qualifying home boundaries, then where the
    /// gap judge sees a closed group's trip end (`splitOnJudgedGaps`). An
    /// evidence gap alone does not split, because assembly keeps it in one group.
    /// A closed group with no destination, which assembly drops, is listed
    /// by its transit stays when it clears the score that opens a provisional
    /// trip for an open one: an outing shown as a trip while it lasted does
    /// not vanish when it ends.
    /// Derived from the STORE, not from the per-pass fingerprint memo,
    /// so the list is correct straight after a relaunch (the memo starts
    /// empty until the first pass).
    func suppressedGroups() -> [SuppressedGroup] {
        let all = (try? modelContext.fetch(FetchDescriptor<Stay>(
            sortBy: [SortDescriptor(\.startTime)]))) ?? []
        // Hide residue claimed by current measured membership at the stay's time because healing will convert it.
        // Do not use the circle fallback: it would hide legitimate suppressed groups offered for review.
        // Passes derive orbits only where they read them, so this list derives
        // its own from the present store; unreadable inputs show nothing.
        guard let homes = try? fetchRequiredAnchors(), primeHomeOrbits(anchors: homes) else { return [] }
        let homeRings = withShapes(homes.map { Self.HomeRing($0) })
        func claimedByMembership(_ stay: Stay) -> Bool {
            for ring in homeRings {
                guard let membership = ring.membership else { continue }
                if let endedAt = ring.endedAt, stay.startTime > endedAt { continue }
                if ring.startedAt > stay.startTime { continue }
                if membership.contains(latitude: stay.centroidLatitude,
                                       longitude: stay.centroidLongitude,
                                       at: stay.startTime) {
                    return true
                }
            }
            return false
        }
        // Fetched locally: the actor's per-pass set is empty after a relaunch.
        let visitBacked = Set(((try? modelContext.fetch(FetchDescriptor<Visit>(
            predicate: #Predicate<Visit> { $0.stayID != nil }))) ?? []).compactMap(\.stayID))
        func qualifies(_ stay: Stay) -> Bool {
            Self.isQualifyingHomeBoundary(
                category: stay.category, source: stay.source,
                startTime: stay.startTime, endTime: stay.endTime,
                pingCount: stay.pingCount, hasVisit: visitBacked.contains(stay.id))
        }
        let homeStays = all.filter { $0.category == .home }
        let gapEvidence = TripGapEvidence(
            homeStays: homeStays, homeRings: homeRings,
            boundaries: HomeBoundaryIndex(homeStays.filter(qualifies).map {
                HomeBoundarySpan(start: $0.startTime, end: $0.endTime)
            }))
        var groups: [[Stay]] = []
        var current: [Stay] = []
        func close(atHome: Bool) {
            for piece in current.isEmpty ? [] : splitOnJudgedGaps(current, evidence: gapEvidence) {
                let destinations = piece.filter { $0.category == .destination }
                if !destinations.isEmpty {
                    groups.append(destinations)
                } else if atHome, groupScoreClears(piece, memberships: Self.gateMemberships(
                    stayStarts: piece.map(\.startTime), rings: homeRings), admitsUnscored: false) {
                    groups.append(piece)
                }
            }
            current = []
        }
        for stay in all {
            if qualifies(stay) {
                close(atHome: true)
            } else if stay.category == .destination || stay.category == .transit, stay.trip == nil,
                      !stay.userOverridden, !claimedByMembership(stay) {
                current.append(stay)
            }
            // Trip members, unclassified, non-qualifying home: not
            // reviewable, but they don't SPLIT a group either — only a
            // qualifying home boundary does (mirrors assembly).
        }
        close(atHome: false)
        return groups.map { members in
            var places: [String: Int] = [:]
            for stay in members {
                if let name = stay.locality ?? stay.islandName {
                    places[name, default: 0] += 1
                }
            }
            return SuppressedGroup(
                id: members[0].id,
                stayIDs: members.map(\.id),
                start: members[0].startTime,
                end: members.map(\.endTime).max() ?? members[0].endTime,
                placeName: places.max(by: {
                    $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value
                })?.key,
                dwellHours: members.reduce(0.0) {
                    $0 + $1.endTime.timeIntervalSince($1.startTime)
                } / 3600.0,
                maxDistanceKm: members.map(\.distanceFromHomeKm).max() ?? 0)
        }
    }

    /// Arm A — "Log as a trip". Marks the group's stays `userOverridden`,
    /// which the confidence gate exempts (the user answered the question;
    /// the score does not overrule them), so the next assembly pass mints
    /// the trip through the normal path. A group of transit stays only
    /// becomes a trip with its longest stay, a non-airport one first, set as
    /// its destination. Re-fetches by id and re-validates
    /// (the gated re-validation pattern): a stay that gained a trip or
    /// vanished since the list rendered is skipped. Returns how many stays
    /// were stamped; 0 means nothing to do, nil that the read or the save
    /// failed and nothing was stamped.
    func logSuppressedGroupAsTrip(stayIDs: [UUID]) -> Int? {
        // Rollback is context-wide; preserve earlier pending edits first.
        if modelContext.hasChanges {
            do {
                try modelContext.save()
            } catch {
                logger.error("Log as a trip pre-save failed: \(error.localizedDescription)")
                return nil
            }
        }
        let wanted = Set(stayIDs)
        var stays: [Stay]
        do {
            stays = try modelContext.fetch(FetchDescriptor<Stay>())
                .filter { wanted.contains($0.id) && $0.trip == nil
                          && ($0.category == .destination || $0.category == .transit) }
        } catch {
            logger.error("Log as a trip skipped; stays unreadable: \(error.localizedDescription)")
            return nil
        }
        if stays.contains(where: { $0.category == .destination }) {
            stays = stays.filter { $0.category == .destination }
        } else if let longest = stays.filter({ !$0.userOverridden }).max(by: {
            ($0.isAirport ? 0 : 1, $0.durationMinutes) < ($1.isAirport ? 0 : 1, $1.durationMinutes)
        }) {
            // Every automatic copy of it; a twin the user set keeps its category.
            stays = stays.filter { $0.id == longest.id && !$0.userOverridden }
            for stay in stays { stay.category = .destination }
        } else {
            stays = []
        }
        guard !stays.isEmpty else { return 0 }
        for stay in stays { stay.userOverridden = true }
        do {
            #if DEBUG
            if shouldFailNextLogAsTripSaveForTesting {
                shouldFailNextLogAsTripSaveForTesting = false
                throw CocoaError(.fileWriteUnknown)
            }
            #endif
            try modelContext.save()
        } catch {
            modelContext.rollback()
            logger.error("Log as a trip save failed: \(error.localizedDescription)")
            return nil
        }
        return stays.count
    }

    /// Single-level in-memory undo for immediate regret; createdOverrideIDs contains only rows this demotion inserted, preserving earlier synced teaching.
    nonisolated struct DemotionUndo: Sendable {
        let createdOverrideIDs: [UUID]
        let tripName: String
        let previousStates: [UUID: (categoryRaw: String, userOverridden: Bool)]
        /// Capture the trip before mutation so undo restores its identity, names, provenance, and deleted photo rows.
        let record: DissolvedTripRecord
        /// Scalar identity of each created row, so undo also withdraws the
        /// copies a nearby Home edit carried to a successor era.
        var createdTeachings: [TaughtCorrection] = []
    }

    /// A taught correction's era-independent identity. Carried copies keep
    /// the kind, centre and creation date of the row they copy.
    nonisolated struct TaughtCorrection: Sendable, Equatable {
        let kindRaw: String
        let latitude: Double
        let longitude: Double
        let createdAt: Date

        func matches(kindRaw: String, latitude: Double, longitude: Double,
                     createdAt: Date) -> Bool {
            // Millisecond tolerance: a synced copy's date can lose sub-ms bits.
            kindRaw == self.kindRaw
                && HomeAreaOverrideDeduplicator.placeKey(
                    kindRaw: kindRaw, latitude: latitude, longitude: longitude)
                == HomeAreaOverrideDeduplicator.placeKey(
                    kindRaw: self.kindRaw, latitude: self.latitude, longitude: self.longitude)
                && abs(createdAt.timeIntervalSince(self.createdAt)) < 0.001
        }
    }

    nonisolated enum DemotionUndoOutcome: Sendable, Equatable {
        /// The trip is back with its identity and photo rows, and the taught includes are withdrawn.
        case undone
        /// No demotion is waiting to be undone.
        case unavailable
        /// The reversal did not finish. The undo token and the queued recovery record stand, so Undo can be retried.
        case failed
    }

    nonisolated enum DemotionOutcome: Sendable, Equatable {
        /// Committed: the trip is gone, its includes are taught, and Undo holds this name.
        case demoted(tripName: String)
        /// Nothing to demote: the tapped row is gone, empty, or has no non-transit cluster.
        case unavailable
        /// A required read, the recovery record or the save failed. Nothing was committed
        /// and an earlier demotion's undo token stands.
        case failed
    }

    /// Teach an include for every non-transit cluster so removeOverride → unHomeStays can withdraw the entire correction.
    /// Stamp every member home and userOverridden even without measured membership. Delete photo annotations
    /// explicitly because they have no inverse relationship for SwiftData cascading.
    /// Acts only on the tapped physical row, never on a UUID twin. The Trip, Home and override
    /// reads are required before any mutation: an unreadable Home table is not "no home", which
    /// would stamp a nil homeID that applies to every home era.
    /// The MainActor caller unpins, invalidates the photo cache, and reloads widgets.
    func demoteTripToHomeArea(tripID: UUID, tripIdentifier: PersistentIdentifier) -> DemotionOutcome {
        let trip: Trip
        do {
            #if DEBUG
            if failDemotionTripReadForTesting { throw CocoaError(.fileReadUnknown) }
            #endif
            let id = tripID
            let twins = try modelContext.fetch(FetchDescriptor<Trip>(
                predicate: #Predicate<Trip> { $0.id == id }))
            guard let found = twins.first(where: {
                !$0.isDeleted && $0.persistentModelID == tripIdentifier
            }) else { return .unavailable }
            trip = found
        } catch {
            logger.error("Trip demotion skipped; trip unreadable: \(error.localizedDescription)")
            return .failed
        }
        let members = (trip.stays ?? [])
        guard !members.isEmpty else { return .unavailable }

        // Clusters of the trip's non-transit stays — the places the user is
        // saying belong to ordinary life. `isLive: true` deliberately: this
        // is a user decision, not learned evidence, so provenance rules
        // don't apply.
        let observations = members.filter { !$0.isAirport }.map {
            HomeOrbit.StayObservation(
                id: $0.id, start: $0.startTime, end: $0.endTime,
                latitude: $0.centroidLatitude, longitude: $0.centroidLongitude,
                isTransitNode: false, isLive: true)
        }
        let clusters = HomeOrbit.clusters(from: observations)
        guard !clusters.isEmpty else { return .unavailable }

        let name = trip.displayName
        let allHomes: [HomeAnchor]
        let revisions: [UUID: Int]
        let existingRows: [HomeAreaOverride]
        do {
            allHomes = try fetchRequiredAnchors()
            revisions = try fetchRequiredTemporaryHomeDeclarations().revisions
            #if DEBUG
            if failDemotionOverrideReadForTesting { throw CocoaError(.fileReadUnknown) }
            #endif
            existingRows = try modelContext.fetch(FetchDescriptor<HomeAreaOverride>())
        } catch {
            logger.error("Trip demotion skipped; dependencies unreadable: \(error.localizedDescription)")
            return .failed
        }
        let existingKeys = Set(existingRows.map {
            HomeAreaOverrideDeduplicator.identityKey(
                kindRaw: $0.kindRaw, homeID: $0.homeID,
                latitude: $0.centerLatitude, longitude: $0.centerLongitude)
        })
        // Scope to the home active when the trip happened (nearest wins
        // on multi-home; nil only when a successful read found no home row).
        // A temporary home can own it inside its dates; Home rows come
        // first, so a tie stays with the real home. The fallback is a
        // current real home only. A trip that predates every real home
        // is that home's too (`matchesHome`'s real-only prehistory pass): it
        // competes with a backdated temporary home instead of losing by default.
        let currentHome = allHomes.first { !$0.isTemporary && $0.endedAt == nil }
        let prehistory = allHomes.allSatisfy { $0.isTemporary || trip.startDate < $0.startedAt }
        let candidates = (prehistory ? [currentHome].compactMap { $0 } : [])
            + allHomes.filter { $0.covers(trip.startDate) }
        func nearestOwner(latitude: Double, longitude: Double) -> HomeAnchor? {
            candidates
                .min { a, b in
                    HomeOrbit.greatCircleKm(a.latitude, a.longitude, latitude, longitude)
                    < HomeOrbit.greatCircleKm(b.latitude, b.longitude, latitude, longitude)
                } ?? currentHome
        }
        // The temporary home each clustered member is stamped for: its
        // cluster's owner, when that is a temporary home. Keyed by physical
        // row: same-id twins at two places sit in two clusters.
        var temporaryOwners: [ObjectIdentifier: UUID] = [:]
        var createdIDs: [UUID] = []
        var createdTeachings: [TaughtCorrection] = []
        for cluster in clusters {
            let owningHome = nearestOwner(latitude: cluster.latitude, longitude: cluster.longitude)
            if let owningHome, owningHome.isTemporary {
                for member in cluster.members {
                    for stay in members where !stay.isAirport && stay.id == member.id
                        && stay.startTime == member.start
                        && stay.centroidLatitude == member.latitude
                        && stay.centroidLongitude == member.longitude {
                        temporaryOwners[ObjectIdentifier(stay)] = owningHome.id
                    }
                }
            }

            let override = HomeAreaOverride(
                kind: .include,
                centerLatitude: cluster.latitude, centerLongitude: cluster.longitude,
                radiusKm: cluster.radiusKm,
                homeID: owningHome?.id,
                sourceTripName: name)
            // Check-before-insert (CloudKit uniqueness discipline): an
            // identical correction already synced from another device (or
            // taught by an earlier demote at this cluster) folds into it.
            let key = HomeAreaOverrideDeduplicator.identityKey(
                kindRaw: override.kindRaw, homeID: override.homeID,
                latitude: override.centerLatitude, longitude: override.centerLongitude)
            guard !existingKeys.contains(key) else { continue }
            modelContext.insert(override)
            createdIDs.append(override.id)
            createdTeachings.append(TaughtCorrection(
                kindRaw: override.kindRaw, latitude: override.centerLatitude,
                longitude: override.centerLongitude, createdAt: override.createdAt))
        }

        // Snapshot the whole trip BEFORE mutating — undo restores the row
        // itself from this (same id, same names), not a re-assembled twin.
        var record = makeDissolvedRecord(for: trip, dissolvedByDemotion: true)

        var previous: [UUID: (categoryRaw: String, userOverridden: Bool)] = [:]
        for stay in members {
            previous[stay.id] = (stay.categoryRaw, stay.userOverridden)
            stay.category = .home
            // The temporary home whose correction claims it, written with the
            // category. An airport is in no cluster: the same rule at its own position.
            let owner = stay.isAirport
                ? nearestOwner(latitude: stay.centroidLatitude, longitude: stay.centroidLongitude)
                    .flatMap { $0.isTemporary ? $0.id : nil }
                : temporaryOwners[ObjectIdentifier(stay)]
            stay.setTemporaryHomeProvenance(owner, revision: owner.flatMap { revisions[$0] })
            stay.userOverridden = true
            stay.trip = nil
            stay.orderInTrip = nil
        }
        // Delete annotations explicitly because Trip.id references do not cascade.
        // Persist recovery, deleted photo rows included, before deleting the trip so restart or replacement
        // of single-level undo cannot lose it; the caller removes the queue copy after successful undo.
        do {
            let annotations = try deletePhotoAnnotationRows(for: trip) ?? []
            record.photoAnnotations = annotations.isEmpty ? nil : annotations
            try persistDissolvedRecords([record])
        } catch {
            modelContext.rollback()
            logger.error("Trip demotion aborted because its recovery record could not be persisted: \(error.localizedDescription)")
            return .failed
        }
        modelContext.delete(trip)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            logger.error("Trip demotion save failed: \(error.localizedDescription)")
            return .failed
        }
        parkedDissolvedTrips.append(record)
        lastDemotion = DemotionUndo(createdOverrideIDs: createdIDs, tripName: name,
                                    previousStates: previous, record: record,
                                    createdTeachings: createdTeachings)
        return .demoted(tripName: name)
    }

    /// HiddenPhoto / PinnedPhoto rows for a trip about to be deleted by a
    /// classifier-side path (Arm B). Mirrors the view-side
    /// `deletePhotoAnnotations` used by delete/merge, including its rule that
    /// a populated UUID twin keeps the rows keyed to the shared UUID.
    /// Returns exactly the deleted rows for the recovery record, or nil when
    /// such a twin keeps them.
    func deletePhotoAnnotationRows(
        for trip: Trip
    ) throws -> [DissolvedTripRecord.PhotoAnnotationRef]? {
        let tripID = trip.id
        let removed = trip.persistentModelID
        let twins = try modelContext.fetch(FetchDescriptor<Trip>(
            predicate: #Predicate<Trip> { $0.id == tripID }))
        guard !twins.contains(where: { $0.persistentModelID != removed && !($0.stays ?? []).isEmpty }) else {
            return nil
        }
        return try deletePhotoAnnotationRows(keyedTo: tripID)
    }

    /// Deletes every HiddenPhoto / PinnedPhoto row keyed to `tripID`, for a
    /// path that deletes every row with the id, and returns them.
    func deletePhotoAnnotationRows(
        keyedTo tripID: UUID
    ) throws -> [DissolvedTripRecord.PhotoAnnotationRef] {
        var refs: [DissolvedTripRecord.PhotoAnnotationRef] = []
        let hidden = try modelContext.fetch(FetchDescriptor<HiddenPhoto>(
            predicate: #Predicate { $0.tripID == tripID }))
        for row in hidden {
            refs.append(.init(
                id: row.id, isPinned: false, localIdentifier: row.localIdentifier,
                cloudIdentifier: row.cloudIdentifier, date: row.hiddenAt))
            modelContext.delete(row)
        }
        let pinned = try modelContext.fetch(FetchDescriptor<PinnedPhoto>(
            predicate: #Predicate { $0.tripID == tripID }))
        for row in pinned {
            refs.append(.init(
                id: row.id, isPinned: true, localIdentifier: row.localIdentifier,
                cloudIdentifier: row.cloudIdentifier, date: row.pinnedAt))
            modelContext.delete(row)
        }
        return refs
    }

    /// Insert the record's photo rows that are absent for its trip, so a retried or repeated restore stays
    /// idempotent. Reads fail closed; the caller commits the rows with the trip or rolls both back.
    func insertMissingPhotoAnnotations(of record: DissolvedTripRecord) throws {
        let refs = record.photoAnnotations ?? []
        guard !refs.isEmpty else { return }
        let tripID = record.id
        let hidden = Set(try fetchForDissolvedRestore(FetchDescriptor<HiddenPhoto>(
            predicate: #Predicate { $0.tripID == tripID })).map(\.localIdentifier))
        let pinned = Set(try fetchForDissolvedRestore(FetchDescriptor<PinnedPhoto>(
            predicate: #Predicate { $0.tripID == tripID })).map(\.localIdentifier))
        for ref in refs {
            if ref.isPinned {
                guard !pinned.contains(ref.localIdentifier) else { continue }
                let row = PinnedPhoto(localIdentifier: ref.localIdentifier, tripID: tripID)
                row.id = ref.id
                row.cloudIdentifier = ref.cloudIdentifier
                row.pinnedAt = ref.date
                modelContext.insert(row)
            } else {
                guard !hidden.contains(ref.localIdentifier) else { continue }
                let row = HiddenPhoto(localIdentifier: ref.localIdentifier, tripID: tripID)
                row.id = ref.id
                row.cloudIdentifier = ref.cloudIdentifier
                row.hiddenAt = ref.date
                modelContext.insert(row)
            }
        }
    }

    /// Reverse the last demotion with its original identity, categories, override flags, and photo rows.
    /// Remove taught includes, and their carried copies, in one removal unit so sibling stays already healed by those discs are freed too.
    /// Report `.undone` only once the trip and its photo rows committed; every failure keeps the undo token.
    func undoLastDemotion() async -> DemotionUndoOutcome {
        guard let undo = lastDemotion else { return .unavailable }
        let stays = ((try? modelContext.fetch(FetchDescriptor<Stay>())) ?? [])
            .filter { undo.previousStates[$0.id] != nil }
        // Retain undo until stays are available so incomplete hydration can retry.
        guard !stays.isEmpty else { return .failed }
        lastDemotion = nil
        // Restore FIRST: once these stays are back on their previous
        // categories, `removeOverride`'s sacred-freeing pass below can't
        // touch them (it frees only `.home` stays).
        for stay in stays {
            guard let prev = undo.previousStates[stay.id] else { continue }
            stay.categoryRaw = prev.categoryRaw
            stay.userOverridden = prev.userOverridden
            // The raw write skips the setter. A trip member was not home
            // before its demotion, so it had no provenance to restore; the
            // restore below puts back any its record holds.
            stay.setTemporaryHomeProvenance(nil, revision: nil)
        }
        // Re-mint the trip row itself: the stays are back on their previous
        // categories with `trip == nil`, exactly what the restore path
        // re-attaches. Sacred stamps are NOT added — the stays carry their
        // pre-demote flags, and the withdrawn teaching removes the claim.
        // The stays, the trip, and its photo rows commit in one save. A trip
        // row that synced back first is reused: the stays it lacks are
        // reattached to it (`.restored`), and when it holds them all
        // (`.alreadyExists`) the stays and the photo rows commit before
        // returning, so it is a success too. Every other outcome rolls back
        // to the demoted state: missing, claimed or twin stay rows (the record's
        // retry-after-convergence cases) would otherwise free the stays for
        // assembly to re-mint under a new UUID, stranding the queued record
        // and the photo rows only it holds.
        switch restoreDissolvedTrip(undo.record, markStaysSacred: false) {
        case .restored, .alreadyExists:
            break
        case .staysClaimed, .staysMissing, .staysAmbiguous, .saveFailed:
            modelContext.rollback()
            lastDemotion = undo
            return .failed
        }
        // Earlier teaching that a check-before-insert or a carry skip kept
        // has its own creation date, so it matches neither selector and stays.
        let createdIDs = Set(undo.createdOverrideIDs)
        let withdrawn = removeOverrideRows(unit: "Undo override withdrawal") { rows in
            rows.filter { row in
                createdIDs.contains(row.id) || undo.createdTeachings.contains {
                    $0.matches(kindRaw: row.kindRaw, latitude: row.centerLatitude,
                               longitude: row.centerLongitude, createdAt: row.createdAt)
                }
            }
        }
        guard withdrawn != nil else {
            lastDemotion = undo
            return .failed
        }
        // The restore read the home places before the removals above freed the
        // siblings' healed stays; re-derive its summary. The trip is already
        // back, so a failed save keeps the restored summary and the undo stands.
        let tripID = undo.record.id
        do {
            let trips = try modelContext.fetch(FetchDescriptor<Trip>(
                predicate: #Predicate { $0.id == tripID }))
            TripTitleStore.invalidateHomePlaceIndex()
            for trip in trips where !(trip.stays ?? []).isEmpty { trip.recomputeSummary() }
            if modelContext.hasChanges { try modelContext.save() }
        } catch {
            modelContext.rollback()
            // Never serve a home-place snapshot built from rolled-back rows.
            TripTitleStore.invalidateHomePlaceIndex()
            logger.error("Undo summary refresh failed: \(error.localizedDescription)")
        }
        return .undone
    }

    // MARK: - Retroactive healing

    /// Never delete or re-judge an interacted trip; interactions arguments and HomeAreaHealingTests.allCases coverage must expand with every interaction surface.
    nonisolated enum TripInteraction: CaseIterable, Sendable {
        case userEdited
        case customName
        case pinned
        case hiddenPhoto
        case pinnedPhoto
        /// A stay override affirms the trip and must prevent healing from dissolving and re-minting it.
        case stayOverridden
    }

    nonisolated static func interactions(
        userEdited: Bool, hasCustomName: Bool, isPinned: Bool,
        hasHiddenPhoto: Bool, hasPinnedPhoto: Bool, hasOverriddenStay: Bool
    ) -> Set<TripInteraction> {
        var out: Set<TripInteraction> = []
        if userEdited { out.insert(.userEdited) }
        if hasCustomName { out.insert(.customName) }
        if isPinned { out.insert(.pinned) }
        if hasHiddenPhoto { out.insert(.hiddenPhoto) }
        if hasPinnedPhoto { out.insert(.pinnedPhoto) }
        if hasOverriddenStay { out.insert(.stayOverridden) }
        return out
    }

    /// Healing is event-driven by override, orbit-disc, and home membership changes.
    /// Prime first and include disc validity windows because shifting an era changes which historical stays are claimed.
    /// Nil when a required read failed: an unreadable input is not an unchanged one.
    func homeAreaFingerprint() async -> String? {
        guard await primeHomeShapes(),
              let overrideRows = try? modelContext.fetch(FetchDescriptor<HomeAreaOverride>()),
              let homeRows = try? fetchRequiredAnchors() else { return nil }
        let overrides = overrideRows
            .map { row in
                String(format: "%@|%@|%.4f|%.4f|%.2f",
                       row.kindRaw, row.homeID?.uuidString ?? "-",
                       row.centerLatitude, row.centerLongitude, row.radiusKm)
            }
            .sorted()
            .joined(separator: ";")
        let discs = resolvedHomeOrbits
            .flatMap { key, discs in
                discs.map { disc in
                    let windows = disc.validity
                        .map { "\(Int($0.start.timeIntervalSinceReferenceDate))-\(Int($0.end.timeIntervalSinceReferenceDate))" }
                        .joined(separator: ",")
                    return String(format: "%@|%.4f|%.4f|%.2f|%@",
                                  key, disc.centerLatitude, disc.centerLongitude,
                                  disc.radiusKm, windows)
                }
            }
            .sorted()
            .joined(separator: ";")
        // Include home rows because added or edited eras change membership even when no new disc is derived.
        let homes = homeRows
            .map { home in
                String(format: "%@|%.4f|%.4f|%.1f|%d|%d",
                       home.id.uuidString, home.latitude, home.longitude,
                       home.radiusKm,
                       Int(home.startedAt.timeIntervalSinceReferenceDate),
                       Int((home.endedAt ?? .distantFuture).timeIntervalSinceReferenceDate))
            }
            .sorted()
            .joined(separator: ";")
        // The version names the healing rule: a change to what dissolves a
        // trip moves it, so a stamped install heals once against the new rule
        // (v4: transit stops outside home keep no trip). The coverage snapshot
        // keeps its key, so the shrink arm sees unchanged geometry.
        let fingerprint = "v4|orbit=true|\(overrides)#\(discs)#\(homes)"
        // Healing leaves a trip whose id several rows hold until they converge.
        // That deferred work is part of the input: when a cohort's row count
        // changes, the fingerprint moves and the heal runs again. A store with
        // no such cohort keeps the fingerprint it had.
        var tripIDs = FetchDescriptor<Trip>()
        tripIDs.propertiesToFetch = [\.id]
        guard let tripRows = try? modelContext.fetch(tripIDs) else { return nil }
        var rowCounts: [UUID: Int] = [:]
        for row in tripRows { rowCounts[row.id, default: 0] += 1 }
        let cohorts = rowCounts.filter { $0.value > 1 }
            .map { "\($0.key.uuidString)x\($0.value)" }
            .sorted()
            .joined(separator: ";")
        return cohorts.isEmpty ? fingerprint : "\(fingerprint)#twins=\(cohorts)"
    }

    /// Value snapshot for the Settings learned-place list.
    nonisolated struct LearnedPlace: Sendable, Identifiable {
        var id: String { String(format: "%.4f,%.4f", latitude, longitude) }
        let latitude: Double
        let longitude: Double
        let radiusKm: Double
        let returnCount: Int
        let firstReturn: Date?
        let homeID: UUID?
    }

    /// The currently-derived orbit discs across all homes, for display and
    /// for the exclude action. Primes first, so the answer reflects the
    /// present stay history.
    func learnedPlaces() async -> [LearnedPlace] {
        await primeHomeShapes()
        return resolvedHomeOrbits.flatMap { key, discs in
            discs.map {
                LearnedPlace(latitude: $0.centerLatitude,
                             longitude: $0.centerLongitude,
                             radiusKm: $0.radiusKm,
                             returnCount: $0.returnTimes.count,
                             firstReturn: $0.returnTimes.first,
                             homeID: UUID(uuidString: key))
            }
        }
        .sorted { $0.id < $1.id }
    }

    #if DEBUG
    /// DEBUG diagnostics read the same primed shapes and orbits as classification, never a separate derivation.
    func debugHomeAreaSnapshot() async -> DebugHomeAreaSnapshot {
        let fingerprint = await homeAreaFingerprint() ?? "unreadable"
        let overrides = ((try? modelContext.fetch(
            FetchDescriptor<HomeAreaOverride>())) ?? [])
            .map {
                DebugHomeAreaSnapshot.OverrideInfo(
                    id: $0.id, kind: $0.kindRaw,
                    centerLatitude: $0.centerLatitude,
                    centerLongitude: $0.centerLongitude,
                    radiusKm: $0.radiusKm, homeID: $0.homeID,
                    sourceTripName: $0.sourceTripName, createdAt: $0.createdAt)
            }
        let homes = fetchAllAnchors().map { home -> DebugHomeAreaSnapshot.HomeInfo in
            let shape = resolvedHomeShapes[Self.shapeKey(home.latitude, home.longitude)]
            var seedKind = "unprimed"
            var seedName: String?
            var seedID: Int64?
            if let shape {
                switch shape.seed {
                case .urbanCentre(let id, let name):
                    seedKind = "urbanCentre"
                    seedName = name
                    seedID = id
                case .fallbackDisc:
                    seedKind = "fallbackDisc"
                }
            }
            let discs = (resolvedHomeOrbits[home.id.uuidString] ?? []).map {
                DebugHomeAreaSnapshot.Disc(
                    centerLatitude: $0.centerLatitude,
                    centerLongitude: $0.centerLongitude,
                    radiusKm: $0.radiusKm,
                    returnTimes: $0.returnTimes,
                    validity: $0.validity.map {
                        DebugHomeAreaSnapshot.Window(start: $0.start, end: $0.end)
                    })
            }
            return DebugHomeAreaSnapshot.HomeInfo(
                id: home.id, label: home.isTemporary ? "Temporary: \(home.label)" : home.label,
                latitude: home.latitude, longitude: home.longitude,
                startedAt: home.startedAt, endedAt: home.endedAt,
                seedKind: seedKind, seedName: seedName, seedID: seedID,
                areaKm2: shape?.areaKm2,
                dStarKm: shape?.areaEquivalentRadiusKm,
                discs: discs)
        }
        return DebugHomeAreaSnapshot(
            generatedAt: .now,
            homes: homes, overrides: overrides, fingerprint: fingerprint)
    }

    /// Marks the CloudKit schema-seed row (Debug Diagnostics). Display-only
    /// field, never consulted by logic — safe as a marker.
    nonisolated static let debugSchemaSeedSourceName = "CloudKit schema seed (DEBUG)"

    /// The schema-seed override if present. DEBUG diagnostics only.
    func debugSchemaSeedRow() -> (id: UUID, createdAt: Date)? {
        ((try? modelContext.fetch(FetchDescriptor<HomeAreaOverride>())) ?? [])
            .first { $0.sourceTripName == Self.debugSchemaSeedSourceName }
            .map { ($0.id, $0.createdAt) }
    }
    #endif

    /// The exclude half of the learned-places list: persist an `.exclude`
    /// override at the disc's spot (bars re-qualification at derivation AND
    /// suppresses coverage at query time), check-before-insert like Arm B.
    @discardableResult
    func excludeLearnedPlace(_ place: LearnedPlace) -> Bool {
        let previousOrbits = resolvedHomeOrbits
        let previousDigests = resolvedHomeOrbitInputDigests
        do {
            let key = HomeAreaOverrideDeduplicator.identityKey(
                kindRaw: HomeAreaOverride.Kind.exclude.rawValue, homeID: place.homeID,
                latitude: place.latitude, longitude: place.longitude)
            let existing = try modelContext.fetch(FetchDescriptor<HomeAreaOverride>()).contains {
                HomeAreaOverrideDeduplicator.identityKey(
                    kindRaw: $0.kindRaw, homeID: $0.homeID,
                    latitude: $0.centerLatitude, longitude: $0.centerLongitude) == key
            }
            guard !existing else { return true }
            modelContext.insert(HomeAreaOverride(
                kind: .exclude, centerLatitude: place.latitude,
                centerLongitude: place.longitude, radiusKm: place.radiusKm,
                homeID: place.homeID))
            // Re-judge the disclaimed coverage before committing the exclusion.
            try primeOverrideRemovalOrbits()
            _ = try unHomeStays(nearLatitude: place.latitude, longitude: place.longitude,
                radiusKm: place.radiusKm, persistChanges: false)
            try modelContext.save()
            return true
        } catch {
            modelContext.rollback()
            resolvedHomeOrbits = previousOrbits
            resolvedHomeOrbitInputDigests = previousDigests
            logger.error("Learned-place exclusion rolled back: \(error.localizedDescription)")
            return false
        }
    }

    #if DEBUG
    /// Current full membership coverage, including learned orbit discs and user overrides.
    func currentMembershipCovers(latitude: Double, longitude: Double) async -> Bool {
        await primeHomeShapes()
        let rings = withShapes(fetchAllAnchors().map { Self.HomeRing($0) })
        return Self.matchesHome(stayStart: .now, latitude: latitude,
                                longitude: longitude, homes: rings)
    }
    #endif

    /// Welcome-Home notifications use only the seed, never orbit or taught discs: a work stop must not
    /// consume the away flag before the actual homecoming. Unprimed membership falls back to the declared circle.
    /// Real homes only: a temporary home is not a homecoming, and its read failing must not block one.
    /// Throws when the Homes cannot be read: an unknown home is no evidence of being away.
    func currentHomeSeedCovers(latitude: Double, longitude: Double) async throws -> Bool {
        guard await primeHomeShapes(seedsOnly: true, realHomesOnly: true) else {
            throw CocoaError(.fileReadUnknown)
        }
        let now = Date.now
        // The seed alone decides, so no correction is read.
        let rings = withShapes(try fetchRequiredHomes().map {
            Self.HomeRing(
                latitude: $0.latitude, longitude: $0.longitude,
                radiusKm: $0.radiusKm, startedAt: $0.startedAt, endedAt: $0.endedAt,
                homeID: $0.id
            )
        }, overrides: [])
        for ring in rings {
            if let endedAt = ring.endedAt, now > endedAt { continue }
            if ring.startedAt > now { continue }
            if let membership = ring.membership {
                if membership.seedContains(latitude: latitude, longitude: longitude) {
                    return true
                }
            } else if CLLocation(latitude: ring.latitude, longitude: ring.longitude)
                .distance(from: CLLocation(latitude: latitude, longitude: longitude))
                / 1000.0 <= ring.radiusKm {
                return true
            }
        }
        return false
    }

    /// Healing dissolves only completed, untouched trips whose non-transit members all match home at their own times
    /// (airport and transit stays are not anchors, so a waypoint outside home keeps no trip; an all-transit trip is judged on all of its non-airport stays),
    /// and none whose id another row (a UUID twin) also holds. The MainActor caller snapshots pinnedTripIDs because PinnedTripsStorage lives there.
    /// Reset members to unclassified for the normal pipeline; only the gate or Arm A may mint trips.
    /// A temporary home's stamp is reset only as its own unit may free it (`automaticReleaseAllows`).
    /// staleCoverage holds previous learned/taught footprints so shrinking coverage frees only disclaimed,
    /// non-sacred home stays inside those patches; legacy home stays outside the footprints are untouched.
    /// While the store may still be hydrating, a trip whose stored summary names places its stays do not
    /// give (`TripTitleStore.mayDeriveSummary`) is left whole: its away stays may not have synced yet, and
    /// deleting its row would delete the whole trip on the device that holds them. The heal then reports
    /// `deferred`, so it stays owed and judges the trip again once hydration settles.
    nonisolated struct HomeAreaHealingOutcome: Sendable, Equatable {
        let moved: Int
        let failed: Bool
        /// A claimed trip was left for a heal after hydration settles.
        var deferred = false
    }

    func healHomeAreaCorrections(
        pinnedTripIDs: Set<UUID>,
        staleCoverage: [CoverageDisc] = []
    ) -> HomeAreaHealingOutcome {
        let homes: (anchors: [HomeAnchor], revisions: [UUID: Int], removedIDs: Set<UUID>)
        let overrides: [HomeAreaOverride]
        do {
            homes = try fetchAnchorsForHomeAreaHealing()
            // Required: an exclusion is what keeps an overlapping learned disc
            // from claiming a place, so an unreadable table is not an empty one.
            overrides = try fetchForHomeAreaHealing(FetchDescriptor<HomeAreaOverride>())
        } catch {
            logger.error("Home-area healing Home fetch failed: \(error.localizedDescription)")
            return HomeAreaHealingOutcome(moved: 0, failed: true)
        }
        let homeRings = withShapes(homes.anchors.map { Self.HomeRing($0) }, overrides: overrides)
        guard homeRings.contains(where: { $0.membership != nil }) else {
            return HomeAreaHealingOutcome(moved: 0, failed: false)
        }

        let hiddenTripIDs: Set<UUID>
        let pinnedPhotoTripIDs: Set<UUID>
        let trips: [Trip]
        do {
            hiddenTripIDs = Set(try fetchForHomeAreaHealing(
                FetchDescriptor<HiddenPhoto>()).compactMap(\.tripID))
            pinnedPhotoTripIDs = Set(try fetchForHomeAreaHealing(
                FetchDescriptor<PinnedPhoto>()).compactMap(\.tripID))
            // The guards and the claim read every completed trip's stays:
            // one batched fetch, not a fault per stay.
            var tripDescriptor = FetchDescriptor<Trip>()
            tripDescriptor.relationshipKeyPathsForPrefetching = [\.stays]
            let rows = try fetchForHomeAreaHealing(tripDescriptor)
            // Same-id rows, open ones included, each hold part of one trip: a
            // record per row would be a partial archive under a shared id, and
            // restoring one removes them all. Their trip waits for convergence.
            var rowCounts: [UUID: Int] = [:]
            for row in rows { rowCounts[row.id, default: 0] += 1 }
            trips = rows.filter { $0.isComplete && rowCounts[$0.id] == 1 }
        } catch {
            logger.error("Home-area healing guard fetch failed: \(error.localizedDescription)")
            return HomeAreaHealingOutcome(moved: 0, failed: true)
        }
        var dissolved = 0
        var deferred = false
        var hydrating: Bool?
        var newlyParked: [DissolvedTripRecord] = []
        for trip in trips {
            let members = trip.stays ?? []
            let guardSet = Self.interactions(
                userEdited: trip.userEdited,
                hasCustomName: trip.customName != nil,
                isPinned: pinnedTripIDs.contains(trip.id),
                hasHiddenPhoto: hiddenTripIDs.contains(trip.id),
                hasPinnedPhoto: pinnedPhotoTripIDs.contains(trip.id),
                hasOverriddenStay: members.contains(where: \.userOverridden))
            guard guardSet.isEmpty else { continue }

            // What holds a trip open is a stay away from home, as in assembly:
            // a transit stop or waypoint outside the area does not. A trip of
            // transit stops alone is judged on all of them, as before.
            let places = members.filter { !$0.isAirport }
            let stops = places.filter { $0.category != .transit }
            let anchors = stops.isEmpty ? places : stops
            guard !anchors.isEmpty else { continue }
            let claimed = anchors.allSatisfy { stay in
                Self.matchesHome(
                    stayStart: stay.startTime,
                    latitude: stay.centroidLatitude,
                    longitude: stay.centroidLongitude,
                    homes: homeRings)
            }
            guard claimed else { continue }
            guard TripTitleStore.mayDeriveSummary(
                holdsNamedStays: TripTitleStore.holdsItsNamedStays(trip), hydrating: &hydrating) else {
                deferred = true
                continue
            }

            // Capture full recovery before mutation so the review list or a late-synced pin can restore the trip;
            // HomeAreaHealing.healIfNeeded drains these records.
            newlyParked.append(makeDissolvedRecord(for: trip, dissolvedByDemotion: false))

            for stay in members where !stay.userOverridden {
                // A newer copy's stamp, or one of a declaration this device
                // does not hold, keeps its category and pair.
                if Self.automaticReleaseAllows(
                    stay, liveRevisions: homes.revisions, removedIDs: homes.removedIDs) {
                    stay.category = .unclassified
                }
                stay.trip = nil
                stay.orderInTrip = nil
            }
            modelContext.delete(trip)
            dissolved += 1
        }

        // Reset newly home-covered tripless destinations so preFilterStays classifies them normally
        // instead of offering routine visits as Near-Home Activity.
        var converted = 0
        let residue: [Stay]
        do {
            residue = try fetchForHomeAreaHealing(FetchDescriptor<Stay>())
                .filter { $0.category == .destination && $0.trip == nil && !$0.userOverridden }
        } catch {
            modelContext.rollback()
            logger.error("Home-area healing residue fetch failed: \(error.localizedDescription)")
            return HomeAreaHealingOutcome(moved: 0, failed: true)
        }
        for stay in residue {
            let claimed = Self.matchesHome(
                stayStart: stay.startTime,
                latitude: stay.centroidLatitude,
                longitude: stay.centroidLongitude,
                homes: homeRings)
            if claimed {
                stay.category = .unclassified
                converted += 1
            }
        }

        // Durability BEFORE the deleting save: once the save below lands,
        // these records are the dissolved trips' only restore path.
        if !newlyParked.isEmpty {
            do {
                try persistDissolvedRecords(newlyParked)
            } catch {
                modelContext.rollback()
                logger.error("Home-area healing aborted because recovery records could not be persisted: \(error.localizedDescription)")
                return HomeAreaHealingOutcome(moved: 0, failed: true)
            }
        }
        if dissolved > 0 || converted > 0 {
            do {
                try modelContext.save()
            } catch {
                modelContext.rollback()
                logger.error("Home-area healing save failed: \(error.localizedDescription)")
                return HomeAreaHealingOutcome(moved: 0, failed: true)
            }
        }
        parkedDissolvedTrips.append(contentsOf: newlyParked)

        // Free disclaimed home stays only within prior coverage footprints; unHomeStays rechecks matchesHome at each stay's time.
        var freed = 0
        do {
            for disc in Set(staleCoverage) {
                freed += try unHomeStays(nearLatitude: disc.latitude,
                                         longitude: disc.longitude,
                                         radiusKm: disc.radiusKm)
            }
        } catch {
            modelContext.rollback()
            logger.error("Home-area healing shrink failed: \(error.localizedDescription)")
            // Earlier discs save independently. Report only that committed
            // work so the caller can still reclassify and publish it while
            // leaving the retry stamps untouched.
            return HomeAreaHealingOutcome(
                moved: dissolved + converted + freed,
                failed: true, deferred: deferred)
        }

        return HomeAreaHealingOutcome(
            moved: dissolved + converted + freed,
            failed: false, deferred: deferred)
    }
}
