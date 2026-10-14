//
//  TripClassifier+TemporaryHomeCoverage.swift
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

    /// The sets one temporary-home change acts on, shared by the core and the preview
    /// so they cannot drift. Pure. `target` is the unit's ring after the edit (nil when
    /// its row is gone), `rings` every anchor's in `HomeAnchors.fetch` order. A home
    /// stay's `temporaryHomeID` is the only evidence a temporary home made it home; nil
    /// (a real Home's, or pre-V20) never authorizes a release (`StampAuthority`).
    /// - `candidates`: stays inside the target, not home yet and not set by the user,
    ///   tripless or members of an affected trip.
    /// - `stale`: stamps no ring claims any more, automatic outside a protected trip or
    ///   the tripless stamp of the user's own correction.
    /// - `handoffs`: stamps (tripless when overridden) another temporary home now
    ///   claims, the first in canonical order, a protected trip's members too. A real
    ///   Home's claim never blocks one, so removing the heir still frees the stay.
    /// - `affectedTrips`: every row of the trips the target covers, which the unit
    ///   rebuilds, by geometry and trip id before any category is judged: a member the
    ///   user did not set lies inside, or an engaged trip's dates hold a stay there that
    ///   is or becomes a qualifying home stay. Only an explicit keep exempts one, and a
    ///   stay the user set covers nothing.
    /// - `splitTrips`: affected trips with any interaction (an earlier hold included),
    ///   one per id, each archived before anything changes and its id retired.
    /// - `protectedTrips`: engaged trips a stale stay would expose by assembly's regroup
    ///   rules, or kept and covered, kept whole (`exposed`: which a stale stay exposes).
    ///   Covering wins.
    /// - `mergedTrips` (display only), `remeasuredTrips`: completed trips a stale stay
    ///   exposes, with no interaction or candidate, or with one but a candidate between.
    /// - `deferred`: a newer copy's stamps that would otherwise change.
    /// - `settledMembers`: unclassified, home or routine members the user did not set,
    ///   judged again in trips it keeps or a temporary home kept or stamped (a stamped
    ///   home one only under `StampAuthority`), unless an explicit keep holds the trip.
    /// A home stay the unit may not release is never reset: it keeps its category and pair.
    static func temporaryHomeChangePlan(
        target: HomeRing?, rings: [HomeRing], unitID: UUID, unitIsLive: Bool,
        unitRevision: Int?,
        removedIDs: Set<UUID>, routineRings: [RoutineRing],
        stays: [Stay], trips: [Trip], visitBackedStayIDs: Set<UUID>,
        pinnedTripIDs: Set<UUID>, hiddenTripIDs: Set<UUID>, pinnedPhotoTripIDs: Set<UUID>,
        explicitlyKeptTripIDs: Set<UUID>
    ) -> (candidates: [Stay], stale: [Stay], handoffs: [(stay: Stay, owner: UUID)],
          affectedTrips: [Trip], splitTrips: [(trip: Trip, reasons: Set<TripInteraction>)],
          protectedTrips: [(trip: Trip, reasons: Set<TripInteraction>, exposed: Bool)],
          mergedTrips: [Trip], remeasuredTrips: [Trip], deferred: [Stay],
          settledMembers: [Stay]) {
        let rules = CoveringRules(
            trips: trips, pinnedTripIDs: pinnedTripIDs, hiddenTripIDs: hiddenTripIDs,
            pinnedPhotoTripIDs: pinnedPhotoTripIDs, visitBackedStayIDs: visitBackedStayIDs,
            explicitlyKeptTripIDs: explicitlyKeptTripIDs)
        func isProtected(_ trip: Trip?) -> Bool { rules.isProtected(trip) }
        func claimed(_ stay: Stay, by homes: [HomeRing]) -> Bool {
            matchesHome(stayStart: stay.startTime, latitude: stay.centroidLatitude,
                        longitude: stay.centroidLongitude, homes: homes)
        }
        let authority = StampAuthority(
            unitID: unitID, unitIsLive: unitIsLive, unitRevision: unitRevision,
            removedIDs: removedIDs)
        let temporaryRings = rings.filter(\.isTemporary)

        var candidates: [Stay] = []
        var stale: [Stay] = []
        var handoffs: [(stay: Stay, owner: UUID)] = []
        var deferred: [Stay] = []
        var kept = Set<ObjectIdentifier>()

        // Covering first, from geometry alone: a stay inside the target
        // at its own time covers the trip that holds it, whatever its category,
        // unless the user set it, and a trip the user engaged with whose dates
        // hold one that is, or becomes, a qualifying home stay: assembly would
        // split it there. A stay the user set never becomes home. Only an
        // explicit keep holds a trip whole against covering.
        var covering = Set<UUID>()
        var coveredStays = Set<ObjectIdentifier>()
        if let target {
            var covered: [Stay] = []
            for stay in stays {
                // A tripless home stay is read only where it could split a trip.
                if stay.category == .home, stay.trip == nil,
                   !rules.qualifiesAsHome(stay) || rules.inDates(stay).isEmpty { continue }
                guard claimed(stay, by: [target]) else { continue }
                covered.append(stay)
                coveredStays.insert(ObjectIdentifier(stay))
            }
            func cover(_ trip: Trip) {
                if explicitlyKeptTripIDs.contains(trip.id) {
                    kept.insert(ObjectIdentifier(trip))
                } else {
                    covering.insert(trip.id)
                }
            }
            for stay in covered where !stay.userOverridden {
                if let trip = stay.trip { cover(trip) }
            }
            for stay in covered {
                for trip in rules.coveredByDates(stay) { cover(trip) }
            }
            // Every row of a kept id: a twin goes with its id.
            let keptIDs = Set(trips.filter { kept.contains(ObjectIdentifier($0)) }.map(\.id))
            for trip in trips where keptIDs.contains(trip.id) { kept.insert(ObjectIdentifier(trip)) }
        }
        let affected = trips.filter { covering.contains($0.id) }

        for stay in stays {
            let mayChange = !stay.userOverridden && !isProtected(stay.trip)
            if stay.category == .home {
                // An overridden stay on a trip is a restore the user asked for,
                // never a correction's stamp.
                guard let owner = stay.temporaryHomeID, authority.actsFor(owner),
                      !stay.userOverridden || stay.trip == nil else { continue }
                let current = authority.isCurrent(stay, owner: owner)
                if !claimed(stay, by: rings) {
                    if mayChange || stay.userOverridden {
                        if current { stale.append(stay) } else { deferred.append(stay) }
                    }
                    continue
                }
                let ownerStillClaims = temporaryRings
                    .first { $0.homeID == owner }
                    .map { claimed(stay, by: [$0]) } ?? false
                if !ownerStillClaims,
                   let heir = temporaryOwner(
                       stayStart: stay.startTime, latitude: stay.centroidLatitude,
                       longitude: stay.centroidLongitude, rings: temporaryRings) {
                    if current {
                        handoffs.append((stay: stay, owner: heir))
                    } else {
                        deferred.append(stay)
                    }
                }
                continue
            }
            // One temporary ring has no prehistory pass, so this is exactly its
            // dated match: inside its dates, and inside its area at the stay's time.
            guard coveredStays.contains(ObjectIdentifier(stay)) else { continue }
            // A stay the user set stands, on a trip being split or tripless.
            if !stay.userOverridden, stay.trip.map({ covering.contains($0.id) }) ?? true {
                candidates.append(stay)
            }
        }
        var exposedTrips = Set<ObjectIdentifier>()
        var merged: [Trip] = []
        var remeasured: [Trip] = []
        // The members of the trips this unit rebuilds that are not stamped home
        // are judged again as the core judges them: the pre-filter over the rings
        // after the change makes one home, or else routine, and the rest go back to
        // assembly's pool. Projected here, a remnant going to the pool exposes a
        // protected trip it would join as much as a freed stay, one becoming home
        // is a boundary, and a routine one is neither. An overridden remnant keeps
        // its category, and so does a home stay the unit may not release (another
        // live declaration's stamp, or a newer copy's, which is deferred).
        let joining = Set(candidates.map { ObjectIdentifier($0) })
        var remnants: [Stay] = []
        var remnantHomes = Set<ObjectIdentifier>()
        var remnantRoutines = Set<ObjectIdentifier>()
        var deferredRows = Set(deferred.map { ObjectIdentifier($0) })
        func deferIfNewer(_ stay: Stay) {
            guard authority.defers(stay), deferredRows.insert(ObjectIdentifier(stay)).inserted
            else { return }
            deferred.append(stay)
        }
        for trip in affected {
            for stay in trip.stays ?? [] where !joining.contains(ObjectIdentifier(stay)) {
                let stands = stay.userOverridden || !authority.mayRejudge(stay)
                if !stay.userOverridden { deferIfNewer(stay) }
                let becomesHome = stands
                    ? stay.category == .home : claimed(stay, by: rings)
                let becomesRoutine = stands
                    ? stay.category == .routine
                    : matchesRoutine(stayStart: stay.startTime, latitude: stay.centroidLatitude,
                                     longitude: stay.centroidLongitude, places: routineRings)
                if becomesHome {
                    remnantHomes.insert(ObjectIdentifier(stay))
                } else if becomesRoutine {
                    remnantRoutines.insert(ObjectIdentifier(stay))
                } else {
                    remnants.append(stay)
                }
            }
        }
        let pooled = Set(remnants.map { ObjectIdentifier($0) })
        if !stale.isEmpty || !remnants.isEmpty {
            // The boundaries that remain: every edge of a qualifying home stay
            // that is not being freed, judged as assembly judges one. A stay
            // this same unit stamps home is a boundary by then: a trip it
            // separates from the freed stays is not exposed.
            let freed = Set(stale.map { ObjectIdentifier($0) })
            var edges: [Date] = []
            // The same edges without the stays being stamped: the homes as
            // they stood when the trips were measured.
            var edgesBefore: [Date] = []
            for stay in stays where !freed.contains(ObjectIdentifier(stay)) {
                func qualifies(as category: StayCategory) -> Bool {
                    isQualifyingHomeBoundary(
                        category: category, source: stay.source,
                        startTime: stay.startTime, endTime: stay.endTime,
                        pingCount: stay.pingCount, hasVisit: visitBackedStayIDs.contains(stay.id))
                }
                let key = ObjectIdentifier(stay)
                let after: StayCategory = joining.contains(key) || remnantHomes.contains(key)
                    ? .home
                    : pooled.contains(key) ? .destination
                    : remnantRoutines.contains(key) ? .routine : stay.category
                if qualifies(as: after) {
                    edges += [stay.startTime, stay.endTime]
                }
                if qualifies(as: stay.category) {
                    edgesBefore += [stay.startTime, stay.endTime]
                }
            }
            let (boundariesAfter, boundariesBefore) = (edges, edgesBefore)
            // Whether a stay going to the pool exposes a trip to regrouping. An
            // open trip is exposed by a stay after its last member too: it would
            // join the trip and could hand its id to a larger neighbour.
            func isExposed(_ trip: Trip, boundaries: [Date], by pool: [Stay]) -> Bool {
                let ordered = trip.orderedStays
                guard let span = CoveringRules.span(of: trip),
                      let first = ordered.first, let last = ordered.last else { return false }
                let homeBefore = boundaries.lazy.filter { $0 <= first.startTime }.max()
                let homeAfter = boundaries.lazy.filter { $0 >= last.endTime }.min()
                return pool.contains { stay in
                    if stay.startTime < span.end && stay.endTime > span.start { return true }
                    if stay.startTime >= last.endTime {
                        return homeAfter.map { stay.startTime < $0 } ?? true
                    }
                    if stay.endTime <= first.startTime {
                        return homeBefore.map { stay.endTime > $0 } ?? true
                    }
                    return false
                }
            }
            // Open trips nobody engaged with are regrouped on every pass anyway.
            for trip in trips where trip.isComplete || isProtected(trip) {
                let key = ObjectIdentifier(trip)
                let protected = isProtected(trip)
                // Covering wins: a trip it rebuilds is never kept, merged or remeasured.
                guard !covering.contains(trip.id) else { continue }
                if protected, isExposed(trip, boundaries: boundariesAfter, by: stale + remnants) {
                    kept.insert(key)
                    exposedTrips.insert(key)
                } else if !protected, isExposed(trip, boundaries: boundariesAfter, by: stale) {
                    merged.append(trip)
                } else if protected, trip.isComplete,
                          isExposed(trip, boundaries: boundariesBefore, by: stale) {
                    // A stay stamped here stands between it and the freed
                    // stays: not regrouped, but the home it left is going.
                    remeasured.append(trip)
                }
            }
        }
        func inOrder(_ a: Trip, _ b: Trip) -> Bool {
            if a.startDate != b.startDate { return a.startDate < b.startDate }
            return a.id.uuidString < b.id.uuidString
        }
        let protectedTrips = trips.filter { kept.contains(ObjectIdentifier($0)) }
            .sorted(by: inOrder)
            .map {
                (trip: $0, reasons: rules.reasons(of: $0),
                 exposed: exposedTrips.contains(ObjectIdentifier($0)))
            }
        // Every trip a temporary home kept before, and every edited trip still
        // holding a member a temporary home stamped: once the declaration is
        // removed or no longer claims the member, no plan keeps that trip. A
        // trip the covering rebuilds is not kept, now or earlier.
        let keptEarlier = trips.filter { trip in
            !kept.contains(ObjectIdentifier(trip)) && !covering.contains(trip.id)
                && trip.userEdited
                && (trip.keptByTemporaryHome
                    || (trip.stays ?? []).contains { $0.temporaryHomeID != nil })
        }
        var settled: [Stay] = []
        for trip in protectedTrips.map(\.trip) + keptEarlier {
            // Keep as One Trip authorizes putting its members back.
            let explicit = explicitlyKeptTripIDs.contains(trip.id)
            for stay in trip.stays ?? [] where !stay.userOverridden
                && [StayCategory.unclassified, .home, .routine].contains(stay.category) {
                if explicit || authority.mayRejudge(stay) {
                    settled.append(stay)
                } else {
                    deferIfNewer(stay)
                }
            }
        }
        // One line per split id: the row holding the most stays, every row's reasons.
        var splitByID: [UUID: (trip: Trip, reasons: Set<TripInteraction>)] = [:]
        for trip in affected {
            let reasons = rules.reasons(of: trip)
            guard !reasons.isEmpty else { continue }
            guard let current = splitByID[trip.id] else {
                splitByID[trip.id] = (trip, reasons)
                continue
            }
            let holdsMore = (trip.stays ?? []).count > (current.trip.stays ?? []).count
            splitByID[trip.id] = (holdsMore ? trip : current.trip, current.reasons.union(reasons))
        }
        return (candidates: candidates, stale: stale, handoffs: handoffs,
                affectedTrips: affected.sorted(by: inOrder),
                splitTrips: splitByID.values.sorted { inOrder($0.trip, $1.trip) },
                protectedTrips: protectedTrips, mergedTrips: merged.sorted(by: inOrder),
                remeasuredTrips: remeasured.sorted(by: inOrder), deferred: deferred,
                settledMembers: settled)
    }

    /// The covering rules the plan and discovery share: which trips the
    /// user engaged with, the span assembly regroups a trip by, and the dates
    /// rule, by which an engaged trip whose dates hold a stay inside the area
    /// that is, or becomes, a qualifying home stay is covered. Pure.
    private nonisolated struct CoveringRules {
        let pinnedTripIDs: Set<UUID>
        let hiddenTripIDs: Set<UUID>
        let pinnedPhotoTripIDs: Set<UUID>
        let visitBackedStayIDs: Set<UUID>
        /// The union of every live declaration's kept trips.
        let explicitlyKeptTripIDs: Set<UUID>
        /// The interactions of every trip given, none included.
        private var reasonsByTrip: [ObjectIdentifier: Set<TripInteraction>] = [:]
        /// The trips given that the user engaged with, with their spans.
        private var engaged: [(trip: Trip, span: (start: Date, end: Date))] = []

        init(
            trips: [Trip], pinnedTripIDs: Set<UUID>, hiddenTripIDs: Set<UUID>,
            pinnedPhotoTripIDs: Set<UUID>, visitBackedStayIDs: Set<UUID>,
            explicitlyKeptTripIDs: Set<UUID>
        ) {
            self.pinnedTripIDs = pinnedTripIDs
            self.hiddenTripIDs = hiddenTripIDs
            self.pinnedPhotoTripIDs = pinnedPhotoTripIDs
            self.visitBackedStayIDs = visitBackedStayIDs
            self.explicitlyKeptTripIDs = explicitlyKeptTripIDs
            for trip in trips {
                let reasons = interactions(of: trip)
                reasonsByTrip[ObjectIdentifier(trip)] = reasons
                if !reasons.isEmpty, let span = Self.span(of: trip) {
                    engaged.append((trip: trip, span: span))
                }
            }
        }

        private func interactions(of trip: Trip) -> Set<TripInteraction> {
            TripClassifier.interactions(
                userEdited: trip.userEdited,
                hasCustomName: trip.customName != nil,
                isPinned: pinnedTripIDs.contains(trip.id),
                hasHiddenPhoto: hiddenTripIDs.contains(trip.id),
                hasPinnedPhoto: pinnedPhotoTripIDs.contains(trip.id),
                hasOverriddenStay: (trip.stays ?? []).contains(where: \.userOverridden))
        }

        /// A trip's interactions, a trip not given included; none for no trip.
        func reasons(of trip: Trip?) -> Set<TripInteraction> {
            guard let trip else { return [] }
            return reasonsByTrip[ObjectIdentifier(trip)] ?? interactions(of: trip)
        }

        func isProtected(_ trip: Trip?) -> Bool { !reasons(of: trip).isEmpty }

        /// The span assembly regroups a trip by: an open trip runs to its last member.
        static func span(of trip: Trip) -> (start: Date, end: Date)? {
            let ordered = trip.orderedStays
            guard let first = ordered.first, let last = ordered.last else { return nil }
            let end = trip.isComplete ? trip.endDate ?? last.endTime : last.endTime
            return (first.startTime, end)
        }

        /// The engaged trips given whose dates hold `stay`.
        func inDates(_ stay: Stay) -> [Trip] {
            engaged.filter { stay.startTime < $0.span.end && stay.endTime > $0.span.start }
                .map(\.trip)
        }

        func qualifiesAsHome(_ stay: Stay) -> Bool {
            TripClassifier.isQualifyingHomeBoundary(
                category: .home, source: stay.source,
                startTime: stay.startTime, endTime: stay.endTime,
                pingCount: stay.pingCount, hasVisit: visitBackedStayIDs.contains(stay.id))
        }

        /// The dates rule for a stay inside the area at its own time: the
        /// engaged trips whose dates hold it when it is, or becomes, a
        /// qualifying home stay. A member of an explicitly kept trip keeps its
        /// category, and a stay the user set never becomes home.
        func coveredByDates(_ stay: Stay) -> [Trip] {
            guard qualifiesAsHome(stay) else { return [] }
            let becomesHome = stay.category == .home
                || (!stay.userOverridden
                    && stay.trip.map { !explicitlyKeptTripIDs.contains($0.id) } ?? true)
            return becomesHome ? inDates(stay) : []
        }
    }

    /// The stamps a temporary-home unit may free, hand on or judge again: its own live
    /// id's at or below its revision (or with none), and any removed id's whatever
    /// their revision; another live declaration's wait for that one's unit.
    nonisolated struct StampAuthority {
        let unitID: UUID
        let unitIsLive: Bool
        let unitRevision: Int?
        let removedIDs: Set<UUID>

        func actsFor(_ owner: UUID) -> Bool {
            (owner == unitID && unitIsLive) || removedIDs.contains(owner)
        }

        /// Whether this unit's copy is at least as new as the one that stamped.
        func isCurrent(_ stay: Stay, owner: UUID) -> Bool {
            if removedIDs.contains(owner) { return true }
            guard let unitRevision, let revision = stay.temporaryHomeRevision else { return true }
            return revision <= unitRevision
        }

        /// Whether the unit may reset `stay` to judge it again: any stay but a
        /// home stay a declaration stamped, and that one only when the unit
        /// acts for its stamp.
        func mayRejudge(_ stay: Stay) -> Bool {
            guard stay.category == .home, let owner = stay.temporaryHomeID else { return true }
            return actsFor(owner) && isCurrent(stay, owner: owner)
        }

        /// A home stay the user did not set whose stamp the unit acts for but
        /// a newer copy wrote.
        func defers(_ stay: Stay) -> Bool {
            guard stay.category == .home, !stay.userOverridden,
                  let owner = stay.temporaryHomeID else { return false }
            return actsFor(owner) && !isCurrent(stay, owner: owner)
        }
    }

    /// Whether a release outside a temporary home's unit (healing's shrink repair,
    /// a Home change's stale pass, a withdrawn correction) may free `stay`: an
    /// unstamped stay, a removed id's stamp, or a live one's at or below the copy
    /// this device holds (`liveRevisions`). A newer or unknown copy's is left to its unit.
    nonisolated static func automaticReleaseAllows(
        _ stay: Stay, liveRevisions: [UUID: Int], removedIDs: Set<UUID>
    ) -> Bool {
        guard let owner = stay.temporaryHomeID else { return true }
        if removedIDs.contains(owner) { return true }
        guard let current = liveRevisions[owner] else { return false }
        return stay.temporaryHomeRevision.map { $0 <= current } ?? true
    }

    /// Records the temporary home that now claims each handed-off stay, with
    /// that heir's coverage revision (`revisions`). Its override goes too: the
    /// correction that set it no longer claims the stay.
    static func applyHandoffs(
        _ handoffs: [(stay: Stay, owner: UUID)], revisions: [UUID: Int]
    ) {
        // Provenance lives on home stays only.
        for handoff in handoffs where handoff.stay.category == .home {
            handoff.stay.setTemporaryHomeProvenance(
                handoff.owner, revision: revisions[handoff.owner])
            if handoff.stay.userOverridden { handoff.stay.userOverridden = false }
        }
    }

    /// Each live temporary home's coverage revision: its collapsed row's.
    nonisolated static func coverageRevisions(of rows: [TemporaryHome]) -> [UUID: Int] {
        Dictionary(
            HomeAnchors.collapsingTwins(rows).map { ($0.id, $0.coverageRevision) },
            uniquingKeysWith: { first, _ in first })
    }

    /// Writes `winner`'s content on every row of its id at `revision`, its
    /// place and dates unchanged, past every row's `modifiedAt` so the rows
    /// keep winning wherever they sync (the save worker's End rule).
    static func reissue(
        _ rows: [TemporaryHome], as winner: TemporaryHome, revision: Int, now: Date
    ) {
        let latest = rows.map(\.modifiedAt).max() ?? now
        let modifiedAt = max(now, latest.addingTimeInterval(0.001))
        // The winner's own fields are only ever written with themselves, so
        // the other rows read them unchanged whatever the order.
        for row in rows {
            row.label = winner.label
            row.latitude = winner.latitude
            row.longitude = winner.longitude
            row.radiusKm = winner.radiusKm
            row.locality = winner.locality
            row.administrativeArea = winner.administrativeArea
            row.country = winner.country
            row.isoCountryCode = winner.isoCountryCode
            row.startedAt = winner.startedAt
            row.endedAt = winner.endedAt
            row.timeZoneIdentifier = winner.timeZoneIdentifier
            row.coverageRevision = revision
            row.modifiedAt = modifiedAt
        }
    }

    /// Per live id, a digest of what its unit would read, for the drain to compare with
    /// what its last committed unit left: coverage and revision, every row's kept trips,
    /// each physical stay row (category, override, provenance, trip) stamped outside the
    /// coverage (with its trip's interactions) or, unless user-set, inside it as a
    /// classified non-home stay or a home stay on a trip not kept, and every trip not
    /// explicitly kept that the dates rule covers (`CoveringRules`). `rings` must carry
    /// measured areas (`withShapes`) and `rows` every raw declaration row before twin
    /// collapse, or the digest disagrees with reconciliation; `stays` may be any superset
    /// of the stays these name and `trips` any superset of the trips the user engaged
    /// with whose dates hold a stay inside.
    nonisolated static func temporaryHomeDigests(
        rows: [TemporaryHome], rings: [HomeRing], stays: [Stay], trips: [Trip],
        pinnedTripIDs: Set<UUID>, hiddenTripIDs: Set<UUID>, pinnedPhotoTripIDs: Set<UUID>,
        visitBackedStayIDs: Set<UUID>
    ) -> [UUID: String] {
        func bits(_ value: Double) -> String { String(value.bitPattern) }
        let rowsByID = Dictionary(grouping: rows, by: \.id)
        let removedIDs = Set(rows.filter { $0.removedAt != nil }.map(\.id))
        let explicitlyKept = TemporaryHome.keptTripIDs(of: rows.filter { !removedIDs.contains($0.id) })
        let rules = CoveringRules(
            trips: trips, pinnedTripIDs: pinnedTripIDs, hiddenTripIDs: hiddenTripIDs,
            pinnedPhotoTripIDs: pinnedPhotoTripIDs, visitBackedStayIDs: visitBackedStayIDs,
            explicitlyKeptTripIDs: explicitlyKept)
        var digests: [UUID: String] = [:]
        for declaration in HomeAnchors.collapsingTwins(rows) {
            guard let ring = rings.first(where: { $0.isTemporary && $0.homeID == declaration.id })
            else { continue }
            let kept = TemporaryHome.keptTripIDs(of: rowsByID[declaration.id] ?? [])
            var lines = [
                [
                    "coverage", String(declaration.coverageRevision),
                    bits(declaration.latitude), bits(declaration.longitude),
                    bits(declaration.radiusKm),
                    bits(declaration.startedAt.timeIntervalSinceReferenceDate),
                    declaration.endedAt.map { bits($0.timeIntervalSinceReferenceDate) } ?? "",
                    declaration.locality.map { "=" + $0 } ?? "",
                ].joined(separator: "|"),
                "kept|" + kept.map(\.uuidString).sorted().joined(separator: ","),
            ]
            var covered = Set<UUID>()
            for stay in stays {
                let inside = matchesHome(
                    stayStart: stay.startTime, latitude: stay.centroidLatitude,
                    longitude: stay.centroidLongitude, homes: [ring])
                if inside {
                    for trip in rules.coveredByDates(stay) where !explicitlyKept.contains(trip.id) {
                        covered.insert(trip.id)
                    }
                }
                let kind: String
                switch stay.category {
                case .unclassified:
                    continue
                case .home:
                    if stay.temporaryHomeID == declaration.id, !inside {
                        kind = "a"
                    } else if !stay.userOverridden, let trip = stay.trip,
                              !kept.contains(trip.id), inside {
                        kind = "c"
                    } else {
                        continue
                    }
                default:
                    guard !stay.userOverridden, inside else { continue }
                    kind = "b"
                }
                var fields = [
                    kind, String(describing: stay.persistentModelID), stay.categoryRaw,
                    stay.userOverridden ? "1" : "0",
                    stay.temporaryHomeID?.uuidString ?? "",
                    stay.temporaryHomeRevision.map(String.init) ?? "",
                    stay.trip?.id.uuidString ?? "",
                ]
                if kind == "a" {
                    let reasons = rules.reasons(of: stay.trip)
                    fields.append(TripInteraction.allCases.filter { reasons.contains($0) }
                        .map { "\($0)" }.joined(separator: ","))
                }
                lines.append(fields.joined(separator: "|"))
            }
            lines += covered.map { "d|" + $0.uuidString }
            digests[declaration.id] = SHA256.hash(data: Data(lines.sorted().joined(separator: "\n").utf8))
                .map { String(format: "%02x", $0) }
                .joined()
        }
        return digests
    }

    /// A box holding every point `ring`'s area can claim: its measured seed's
    /// polygons or fallback disc, its include and orbit discs, or its declared
    /// circle while unprimed, each disc reached as `unHomeStays` reaches one.
    /// The longitudes are nil when the box would reach a pole or cross the
    /// antimeridian: latitude alone bounds it then.
    nonisolated static func discoveryBounds(of ring: HomeRing) -> (
        minLatitude: Double, maxLatitude: Double, minLongitude: Double?, maxLongitude: Double?
    ) {
        var discs: [(latitude: Double, longitude: Double, radiusKm: Double)] = []
        var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0
        if let membership = ring.membership {
            let seed = membership.seed
            if seed.rings.isEmpty {
                discs.append((seed.centreLatitude, seed.centreLongitude, HomeShape.fallbackRadiusKm))
            }
            // Flat [longitude, latitude] pairs, outer ring first.
            for polygon in seed.rings {
                guard let outer = polygon.first else { continue }
                for index in stride(from: 0, to: outer.count - 1, by: 2) {
                    minLon = Swift.min(minLon, outer[index] - 0.001)
                    maxLon = Swift.max(maxLon, outer[index] + 0.001)
                    minLat = Swift.min(minLat, outer[index + 1] - 0.001)
                    maxLat = Swift.max(maxLat, outer[index + 1] + 0.001)
                }
            }
            discs += membership.includeDiscs
            discs += membership.orbitDiscs.map {
                ($0.centerLatitude, $0.centerLongitude, $0.radiusKm)
            }
        } else {
            discs.append((ring.latitude, ring.longitude, ring.radiusKm))
        }
        for disc in discs {
            let dLat = disc.radiusKm / 110.0 * 1.05 + 0.001
            let maxAbsLat = Swift.min(89.0, Swift.max(
                abs(disc.latitude - dLat), abs(disc.latitude + dLat)))
            let dLon = dLat / cos(maxAbsLat * .pi / 180)
            minLat = Swift.min(minLat, disc.latitude - dLat)
            maxLat = Swift.max(maxLat, disc.latitude + dLat)
            minLon = Swift.min(minLon, disc.longitude - dLon)
            maxLon = Swift.max(maxLon, disc.longitude + dLon)
        }
        guard minLat <= maxLat else { return (-90, 90, nil, nil) }
        guard maxLat < 89, minLat > -89, minLon > -180, maxLon < 180 else {
            return (minLat, maxLat, nil, nil)
        }
        return (minLat, maxLat, minLon, maxLon)
    }

    /// `temporaryHomeDigests` of every live temporary home as the store holds it,
    /// read on a fresh context (no unit's unsaved work) and bounded to what a digest
    /// names: every stamp, the stays in each one's dates and `discoveryBounds`, the
    /// trips holding them, photo rows and needed visits. Nil when a read failed.
    func temporaryHomeDiscoveryDigests(pinnedTripIDs: Set<UUID> = []) async -> [UUID: String]? {
        let context = ModelContext(modelContainer)
        do {
            let rows = try context.fetch(FetchDescriptor<TemporaryHome>())
            let live = HomeAnchors.collapsingTwins(rows)
            guard !live.isEmpty else { return [:] }
            guard await primeHomeShapes(seedsOnly: true) else { return nil }
            let overrides = try context.fetch(FetchDescriptor<HomeAreaOverride>())
            let rings = withShapes(live.map { HomeRing(HomeAnchor($0)) }, overrides: overrides)
            func projected(_ predicate: Predicate<Stay>) -> FetchDescriptor<Stay> {
                var descriptor = FetchDescriptor<Stay>(predicate: predicate)
                descriptor.propertiesToFetch = [
                    \.id, \.startTime, \.endTime, \.centroidLatitude, \.centroidLongitude,
                    \.categoryRaw, \.userOverridden, \.temporaryHomeID, \.temporaryHomeRevision,
                    \.sourceRaw, \.pingCount,
                ]
                descriptor.relationshipKeyPathsForPrefetching = [\.trip]
                return descriptor
            }
            let homeRaw = StayCategory.home.rawValue
            var fetched = try context.fetch(projected(#Predicate {
                $0.categoryRaw == homeRaw && $0.temporaryHomeID != nil
            }))
            for ring in rings {
                let lower = ring.startedAt
                let upper = ring.endedAt ?? .distantFuture
                guard lower <= upper else { continue }
                let box = Self.discoveryBounds(of: ring)
                let (minLat, maxLat) = (box.minLatitude, box.maxLatitude)
                if let minLon = box.minLongitude, let maxLon = box.maxLongitude {
                    fetched += try context.fetch(projected(#Predicate {
                        $0.startTime >= lower && $0.startTime <= upper
                            && $0.centroidLatitude >= minLat && $0.centroidLatitude <= maxLat
                            && $0.centroidLongitude >= minLon && $0.centroidLongitude <= maxLon
                    }))
                } else {
                    fetched += try context.fetch(projected(#Predicate {
                        $0.startTime >= lower && $0.startTime <= upper
                            && $0.centroidLatitude >= minLat && $0.centroidLatitude <= maxLat
                    }))
                }
            }
            #if DEBUG
            discoveryStayReadCountForTesting = fetched.count
            #endif
            var seen = Set<PersistentIdentifier>()
            let stays = fetched.filter { seen.insert($0.persistentModelID).inserted }
            // The trips the dates rule can reach: their stored dates hold a
            // stay inside, read around each declaration's own stays inside.
            var inside: [Stay] = []
            var trips: [Trip] = []
            var seenTrips = Set<PersistentIdentifier>()
            for ring in rings {
                let mine = stays.filter { stay in
                    Self.matchesHome(stayStart: stay.startTime, latitude: stay.centroidLatitude,
                                     longitude: stay.centroidLongitude, homes: [ring])
                }
                inside += mine
                guard let earliest = mine.map(\.startTime).min(),
                      let latest = mine.map(\.endTime).max() else { continue }
                let open = Date.distantFuture
                var descriptor = FetchDescriptor<Trip>(predicate: #Predicate {
                    $0.startDate < latest && ($0.isComplete == false || ($0.endDate ?? open) > earliest)
                })
                descriptor.propertiesToFetch = [\.startDate, \.endDate, \.isComplete]
                for trip in try context.fetch(descriptor) {
                    let end = trip.isComplete ? trip.endDate ?? .distantFuture : .distantFuture
                    guard mine.contains(where: { $0.startTime < end && $0.endTime > trip.startDate }),
                          seenTrips.insert(trip.persistentModelID).inserted else { continue }
                    trips.append(trip)
                }
            }
            func tripIDs<T: PersistentModel>(_ type: T.Type, _ tripID: KeyPath<T, UUID>) throws -> Set<UUID> {
                var descriptor = FetchDescriptor<T>()
                descriptor.propertiesToFetch = [tripID]
                return Set(try context.fetch(descriptor).map { $0[keyPath: tripID] })
            }
            var visitBacked = Set<UUID>()
            if inside.contains(where: { $0.pingCount == 1 }) {
                var descriptor = FetchDescriptor<Visit>(predicate: #Predicate { $0.stayID != nil })
                descriptor.propertiesToFetch = [\.stayID]
                visitBacked = Set(try context.fetch(descriptor).compactMap(\.stayID))
            }
            return Self.temporaryHomeDigests(
                rows: rows, rings: rings, stays: stays, trips: trips,
                pinnedTripIDs: pinnedTripIDs,
                hiddenTripIDs: try tripIDs(HiddenPhoto.self, \.tripID),
                pinnedPhotoTripIDs: try tripIDs(PinnedPhoto.self, \.tripID),
                visitBackedStayIDs: visitBacked)
        } catch {
            logger.error("Temporary-home discovery skipped; store unreadable: \(error.localizedDescription)")
            return nil
        }
    }
}
