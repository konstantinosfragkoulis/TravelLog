//
//  TemporaryHomeLedger.swift
//  TravelLog
//

import Foundation
import SwiftData

/// Days away (Passport, Siri, new Wrapped recaps): `TravelDays`' trip labels
/// plus the days lived at a temporary home, from evidence, never from dates
/// alone. Its stays are walked in time order; a qualifying home stay another
/// anchor owns (`HomeAnchors.recordedOwner`) is a barrier, and a run counts
/// only when it holds an owned home stay. A run after a barrier starts at its
/// first owned stay (or the transit legs straight before it); only the last
/// run grows to `now`, and only while the temporary home is active.
nonisolated enum TemporaryHomeLedger {

    /// One stay reduced to what the ledger needs.
    nonisolated struct StaySample: Sendable {
        let id: UUID
        let start: Date
        let end: Date
        let latitude: Double
        let longitude: Double
        let categoryRaw: String
        let sourceRaw: String
        let pingCount: Int
        let timeZoneIdentifier: String?
        /// What its home writer recorded (`Stay.temporaryHomeID`).
        var temporaryHomeID: UUID? = nil
    }

    nonisolated struct Span: Sendable, Equatable {
        /// Already clipped to the temporary home's dates and to now.
        let start: Date
        let end: Date
        /// Zones of the stays that supply each boundary.
        let firstZone: String?
        let lastZone: String?
    }

    /// Label sets use `TravelDays` keys; bucket them with `TravelDays.labelCalendar`.
    nonisolated struct Result: Sendable, Equatable {
        /// Exactly the `TravelDays` trip-label set passed in.
        let travelling: Set<Date>
        /// Staying-span labels minus `travelling`.
        let staying: Set<Date>
        /// `travelling` union the staying-span labels.
        let away: Set<Date>
        /// Each `staying` label under exactly one temporary home: the first,
        /// by `startedAt` then id, whose own spans cover it. Homes with none are absent.
        let stayingByHome: [UUID: Set<Date>]
        /// Temporary homes with no evidence are absent.
        let spansByHome: [UUID: [Span]]
    }

    /// The store reads behind the projected adapter. A DEBUG hook can fail
    /// one by name; the adapter throws it.
    enum Read: String, Sendable, CaseIterable {
        case temporaryHomes, stays, visitBacking
    }

    #if DEBUG
    /// Task-local, so a detached worker must re-install it.
    @TaskLocal static var readFailureForTesting: (@Sendable (Read) throws -> Void)?
    #endif

    /// Test checkpoint immediately before a required read; a no-op in release.
    private static func checkRead(_ read: Read) throws {
        #if DEBUG
        try readFailureForTesting?(read)
        #endif
    }

    // MARK: - Pure core

    /// A stay's stored zone as a sort key; nil and empty stay distinct.
    static func zoneRank(_ stay: StaySample) -> String {
        stay.timeZoneIdentifier.map { "=" + $0 } ?? ""
    }

    /// What decides a barrier and an owner, as a sort key for same-id twins
    /// that tie on dates and zone: rows that tie here too are identical.
    static func barrierRank(_ stay: StaySample) -> [String] {
        [stay.categoryRaw, stay.sourceRaw, String(stay.pingCount),
         String(stay.latitude.bitPattern), String(stay.longitude.bitPattern),
         stay.temporaryHomeID?.uuidString ?? ""]
    }

    /// Pure. `stays` in any order; `knownTemporaryHomeIDs` = every temporary
    /// home id with a row, removed ones included.
    static func spans(
        for temporaryHome: HomeAnchor, knownTemporaryHomeIDs: Set<UUID>, stays: [StaySample],
        visitBackedStayIDs: Set<UUID>, now: Date
    ) -> [Span] {
        let upper = min(temporaryHome.endedAt ?? now, now)
        guard temporaryHome.startedAt <= upper else { return [] }
        // Two rows can share a start and an id (same-id twins). The zone, the
        // other boundary date, then what decides a barrier and an owner order
        // them, so the input order never does.
        let timeline = stays
            .filter { $0.start >= temporaryHome.startedAt && $0.start <= upper }
            .sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                if $0.id != $1.id { return $0.id.uuidString < $1.id.uuidString }
                let zones = (zoneRank($0), zoneRank($1))
                if zones.0 != zones.1 { return zones.0 < zones.1 }
                if $0.end != $1.end { return $0.end < $1.end }
                return barrierRank($0).lexicographicallyPrecedes(barrierRank($1))
            }

        // Barriers cut the timeline; the last element is the run no barrier
        // follows. `firstOwn` indexes the run's first stay this home owns.
        var segments: [(stays: [StaySample], firstOwn: Int?)] = [(stays: [], firstOwn: nil)]
        let homeRaw = StayCategory.home.rawValue
        for stay in timeline {
            let owner = stay.categoryRaw == homeRaw
                ? HomeAnchors.recordedOwner(
                    temporaryHomeID: stay.temporaryHomeID, knownTemporaryHomeIDs: knownTemporaryHomeIDs)
                : nil
            let isOwn = owner == .temporary(temporaryHome.id)
            // A home stay at a real Home or at another temporary home ends
            // the run when it would also end a trip: the assembly boundary
            // rule. One whose recorded owner has not synced ends nothing.
            if let owner, !isOwn, owner != .unresolved,
               TripClassifier.isQualifyingHomeBoundary(
                category: .home, source: DataSource.decode(stay.sourceRaw),
                startTime: stay.start, endTime: stay.end,
                pingCount: stay.pingCount, hasVisit: visitBackedStayIDs.contains(stay.id)) {
                segments.append((stays: [], firstOwn: nil))
                continue
            }
            if isOwn, segments[segments.count - 1].firstOwn == nil {
                segments[segments.count - 1].firstOwn = segments[segments.count - 1].stays.count
            }
            segments[segments.count - 1].stays.append(stay)
        }

        let transitRaw = StayCategory.transit.rawValue
        var result: [Span] = []
        for (index, segment) in segments.enumerated() {
            // The latest END supplies the last zone, not the last-started
            // stay; equal ends go to the smaller id, as `TravelDays` does,
            // and same-id twins to the smaller zone, then the earlier start.
            guard let firstOwn = segment.firstOwn,
                  let last = segment.stays.max(by: {
                      if $0.end != $1.end { return $0.end < $1.end }
                      if $0.id != $1.id { return $0.id.uuidString > $1.id.uuidString }
                      let zones = (zoneRank($0), zoneRank($1))
                      if zones.0 != zones.1 { return zones.0 > zones.1 }
                      if $0.start != $1.start { return $0.start > $1.start }
                      return barrierRank($1).lexicographicallyPrecedes(barrierRank($0))
                  }) else { continue }
            // After a barrier the run starts at the first stay this home
            // owns, or at the transit legs that lead straight to it (the
            // journey back), never at an earlier stop such as a trip
            // elsewhere: those days count as trip days, not residence.
            var startIndex = index == 0 ? 0 : firstOwn
            while index > 0, startIndex > 0, segment.stays[startIndex - 1].categoryRaw == transitRaw {
                startIndex -= 1
            }
            let first = segment.stays[startIndex]
            var end = min(last.end, upper)
            if index == segments.count - 1, temporaryHome.covers(now) { end = now }
            result.append(Span(
                start: first.start, end: max(first.start, end),
                firstZone: first.timeZoneIdentifier, lastZone: last.timeZoneIdentifier))
        }
        return result
    }

    /// Pure reducer over label sets. `anchors` may hold Homes too; only the
    /// temporary ones are read. `removedTemporaryHomeIDs` are ids whose
    /// stamps still name them although they show no more.
    static func result(
        travelling: Set<Date>, anchors: [HomeAnchor], stays: [StaySample],
        visitBackedStayIDs: Set<UUID>, removedTemporaryHomeIDs: Set<UUID> = [],
        now: Date, fallbackZone: TimeZone
    ) -> Result {
        result(travelling: travelling, anchors: anchors, stays: stays,
               visitBackedStayIDs: visitBackedStayIDs, removedTemporaryHomeIDs: removedTemporaryHomeIDs,
               now: now, fallbackZone: fallbackZone, checkCancellation: {})
    }

    static func result(
        travelling: Set<Date>, anchors: [HomeAnchor], stays: [StaySample],
        visitBackedStayIDs: Set<UUID>, removedTemporaryHomeIDs: Set<UUID> = [],
        now: Date, fallbackZone: TimeZone, checkCancellation: () throws -> Void
    ) rethrows -> Result {
        let temporaryHomes = anchors.filter(\.isTemporary).sorted {
            $0.startedAt == $1.startedAt
                ? $0.id.uuidString < $1.id.uuidString : $0.startedAt < $1.startedAt
        }
        let knownIDs = Set(temporaryHomes.map(\.id)).union(removedTemporaryHomeIDs)
        var stayingSpanLabels = Set<Date>()
        var labelsInOrder: [(id: UUID, labels: Set<Date>)] = []
        var spansByHome: [UUID: [Span]] = [:]
        for temporaryHome in temporaryHomes {
            try checkCancellation()
            let homeSpans = spans(
                for: temporaryHome, knownTemporaryHomeIDs: knownIDs, stays: stays,
                visitBackedStayIDs: visitBackedStayIDs, now: now)
            guard !homeSpans.isEmpty else { continue }
            spansByHome[temporaryHome.id] = homeSpans
            let labels = try TravelDays.labels(
                forSpans: homeSpans.map {
                    (start: $0.start, end: $0.end, firstZone: $0.firstZone, lastZone: $0.lastZone)
                },
                now: now, fallbackZone: fallbackZone, checkCancellation: checkCancellation)
            labelsInOrder.append((id: temporaryHome.id, labels: labels))
            stayingSpanLabels.formUnion(labels)
        }

        let staying = stayingSpanLabels.subtracting(travelling)
        var stayingByHome: [UUID: Set<Date>] = [:]
        var unassigned = staying
        for entry in labelsInOrder {
            let own = entry.labels.intersection(unassigned)
            guard !own.isEmpty else { continue }
            stayingByHome[entry.id, default: []].formUnion(own)
            unassigned.subtract(own)
        }
        return Result(
            travelling: travelling, staying: staying,
            away: travelling.union(stayingSpanLabels),
            stayingByHome: stayingByHome, spansByHome: spansByHome)
    }

    /// The reducer over what `inputs` read.
    static func result(
        travelling: Set<Date>, inputs: Inputs, now: Date, fallbackZone: TimeZone,
        checkCancellation: () throws -> Void
    ) rethrows -> Result {
        try result(
            travelling: travelling, anchors: inputs.temporaryHomes, stays: inputs.stays,
            visitBackedStayIDs: inputs.visitBackedStayIDs,
            removedTemporaryHomeIDs: inputs.removedTemporaryHomeIDs,
            now: now, fallbackZone: fallbackZone, checkCancellation: checkCancellation)
    }

    // MARK: - Projected adapter

    /// What the projected adapter reads, as values, for callers that derive
    /// more from the same rows (the temporary home cards).
    nonisolated struct Inputs: Sendable {
        /// Same-id twins collapsed, removed ids left out.
        let temporaryHomes: [HomeAnchor]
        /// Ids with a removed row.
        let removedTemporaryHomeIDs: Set<UUID>
        /// Every stay that starts from the earliest temporary home's start to now.
        let stays: [StaySample]
        let visitBackedStayIDs: Set<UUID>
    }

    /// The projected adapter's reads: its own context, scalar projections
    /// only. With no temporary home it returns empty inputs after ONE fetch
    /// (the temporary-home rows). Any failed read throws.
    static func inputs(
        container: ModelContainer, now: Date, checkCancellation: () throws -> Void
    ) throws -> Inputs {
        try checkCancellation()
        let context = ModelContext(container)
        try checkRead(.temporaryHomes)
        let rows = try context.fetch(FetchDescriptor<TemporaryHome>())
        let temporaryHomes = HomeAnchors.collapsingTwins(rows).map { HomeAnchor($0) }
        try checkCancellation()
        guard let earliestStart = temporaryHomes.map(\.startedAt).min() else {
            return Inputs(temporaryHomes: [], removedTemporaryHomeIDs: [], stays: [], visitBackedStayIDs: [])
        }

        // No stay outside every temporary home's dates can join a run.
        let latestStart = now
        var stayDescriptor = FetchDescriptor<Stay>(predicate: #Predicate {
            $0.startTime >= earliestStart && $0.startTime <= latestStart
        })
        stayDescriptor.propertiesToFetch = [
            \.id, \.startTime, \.endTime, \.centroidLatitude, \.centroidLongitude,
            \.categoryRaw, \.sourceRaw, \.pingCount, \.timeZoneIdentifier, \.temporaryHomeID,
        ]
        try checkRead(.stays)
        let stays = try context.fetch(stayDescriptor)
        try checkCancellation()

        var visitDescriptor = FetchDescriptor<Visit>(predicate: #Predicate { $0.stayID != nil })
        visitDescriptor.propertiesToFetch = [\.stayID]
        try checkRead(.visitBacking)
        let visits = try context.fetch(visitDescriptor)
        try checkCancellation()

        return Inputs(
            temporaryHomes: temporaryHomes,
            removedTemporaryHomeIDs: HomeAnchors.removedIDs(rows),
            stays: try stays.map {
                try checkCancellation()
                return StaySample($0)
            },
            visitBackedStayIDs: Set(visits.compactMap(\.stayID)))
    }

    /// Projected adapter for Siri and Wrapped. With no temporary home it
    /// returns `travelling` unchanged after ONE fetch (the temporary-home
    /// rows). Any failed read throws.
    static func result(
        travelling: Set<Date>, container: ModelContainer, now: Date,
        fallbackZone: TimeZone, checkCancellation: () throws -> Void
    ) throws -> Result {
        try result(
            travelling: travelling,
            inputs: inputs(container: container, now: now, checkCancellation: checkCancellation),
            now: now, fallbackZone: fallbackZone, checkCancellation: checkCancellation)
    }
}

nonisolated extension TemporaryHomeLedger.StaySample {
    /// Stored fields only, so a projected row never faults its heavy columns.
    init(_ stay: Stay) {
        self.init(
            id: stay.id, start: stay.startTime, end: stay.endTime,
            latitude: stay.centroidLatitude, longitude: stay.centroidLongitude,
            categoryRaw: stay.categoryRaw, sourceRaw: stay.sourceRaw,
            pingCount: stay.pingCount, timeZoneIdentifier: stay.timeZoneIdentifier,
            temporaryHomeID: stay.temporaryHomeID)
    }
}
