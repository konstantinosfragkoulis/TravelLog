//
//  SharedTripImportPlan.swift
//  TravelLog
//
//  Recipient side, the pure part: which of a shared trip's fixes may enter
//  this store. Import is at the evidence level: the fixes go in as
//  `.sharedImport` pings and the normal pipeline clusters, classifies and
//  assembles them against this user's own Homes, so boundaries, distances and
//  home logic are theirs. The recipient's own evidence always wins:
//  - a fix within `ownEvidencePadding` of any of their own pings, stays or
//    Visits is dropped, so shared evidence only fills their gaps and is never
//    folded into a stay of their own;
//  - a fix inside one of their home anchors at its time is dropped;
//  - a fix whose UUID is already stored (an earlier import of the same share,
//    or their own row coming back) is skipped.
//
//  A shared Visit enters as two fixes at its arrival and departure under ids
//  derived from the Visit's own: `Visit` has no provenance column, and a raw
//  Visit row would read as this user's own Core Location visit (a live stay,
//  measured home dwell).
//

import CryptoKit
import Foundation
import SwiftData

nonisolated enum SharedTripImportPlan {

    /// The clustering gap: a shared fix this close to the user's own evidence
    /// could join one of their stays, so it is left out.
    static var ownEvidencePadding: TimeInterval { StayClusterer.timeGapThresholdSeconds }

    struct Admission: Sendable, Equatable {
        var admitted: [SharedPing] = []
        var droppedForOwnEvidence = 0
        var droppedInsideHome = 0
        var alreadyPresent = 0
    }

    /// The trip's fixes plus its Visits' arrival and departure fixes, one per
    /// id, in time order.
    static func evidence(of trip: SharedTrip) -> [SharedPing] {
        var byID: [UUID: SharedPing] = [:]
        for ping in trip.pings where ping.isPlausible { byID[ping.id] = byID[ping.id] ?? ping }
        for visit in trip.visits where visit.isPlausible {
            for ping in visitPings(visit) { byID[ping.id] = byID[ping.id] ?? ping }
        }
        return byID.values.sorted { ($0.timestamp, $0.id.uuidString) < ($1.timestamp, $1.id.uuidString) }
    }

    static func visitPings(_ visit: SharedVisit) -> [SharedPing] {
        var times = [(visit.arrivalDate, "arrival")]
        if let departure = visit.departureDate, departure > visit.arrivalDate {
            times.append((departure, "departure"))
        }
        return times.map { date, tag in
            SharedPing(
                id: derivedID(visit.id, tag), timestamp: date,
                latitude: visit.latitude, longitude: visit.longitude,
                horizontalAccuracy: visit.horizontalAccuracy,
                sourceRaw: "visit")
        }
    }

    /// A stable name-based UUID, so a re-import derives the same ids.
    static func derivedID(_ id: UUID, _ tag: String) -> UUID {
        let digest = SHA256.hash(data: Data("travellog.shared-visit.\(id.uuidString).\(tag)".utf8))
        var b = Array(digest.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// Sorted, disjoint intervals covering every instant `padding` or less
    /// from one of `spans`.
    static func merged(_ spans: [(start: Date, end: Date)], padding: TimeInterval) -> [DateInterval] {
        let padded = spans.map {
            (start: $0.start.addingTimeInterval(-padding), end: max($0.start, $0.end).addingTimeInterval(padding))
        }.sorted { $0.start < $1.start }
        var result: [DateInterval] = []
        for span in padded {
            if let last = result.last, span.start <= last.end {
                result[result.count - 1] = DateInterval(start: last.start, end: max(last.end, span.end))
            } else {
                result.append(DateInterval(start: span.start, end: span.end))
            }
        }
        return result
    }

    static func covers(_ intervals: [DateInterval], _ date: Date) -> Bool {
        var low = 0
        var high = intervals.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let interval = intervals[mid]
            if date < interval.start { high = mid - 1 }
            else if date > interval.end { low = mid + 1 }
            else { return true }
        }
        return false
    }

    /// The instants near this user's own evidence between `start` and `end`:
    /// every ping, stay and Visit that is not shared, padded each side.
    static func ownEvidenceIntervals(
        in context: ModelContext, from start: Date, to end: Date, padding: TimeInterval
    ) throws -> [DateInterval] {
        let low = start.addingTimeInterval(-padding)
        let high = end.addingTimeInterval(padding)
        let shared = DataSource.sharedImport.rawValue
        var spans: [(start: Date, end: Date)] = []
        var pingDescriptor = FetchDescriptor<LocationPing>(predicate: #Predicate {
            $0.timestamp >= low && $0.timestamp <= high && $0.sourceRaw != shared
        })
        pingDescriptor.propertiesToFetch = [\.timestamp]
        spans += try context.fetch(pingDescriptor).map { ($0.timestamp, $0.timestamp) }
        var stayDescriptor = FetchDescriptor<Stay>(predicate: #Predicate {
            $0.startTime <= high && $0.endTime >= low && $0.sourceRaw != shared
        })
        stayDescriptor.propertiesToFetch = [\.startTime, \.endTime]
        spans += try context.fetch(stayDescriptor).map { ($0.startTime, $0.endTime) }
        // A Visit can stay open for days: read arrivals well before the window.
        let visitLow = low.addingTimeInterval(-30 * 86_400)
        let visits = try context.fetch(FetchDescriptor<Visit>(predicate: #Predicate {
            $0.arrivalDate >= visitLow && $0.arrivalDate <= high
        }))
        for visit in visits {
            let end = visit.departureDate ?? max(visit.arrivalDate, visit.receivedAt)
            if end >= low { spans.append((visit.arrivalDate, end)) }
        }
        return merged(spans, padding: padding)
    }

    /// Everything the home rings are measured from that a write can change
    /// while an import runs: the Homes, the temporary homes and the taught
    /// corrections, in a stable order. Equal digests read before the rings
    /// and inside a recording unit mean the rings still describe the store.
    static func homeDependencyDigest(in context: ModelContext) throws -> [String] {
        func time(_ date: Date?) -> String {
            date.map { String($0.timeIntervalSinceReferenceDate) } ?? "-"
        }
        var digest: [String] = []
        for home in try context.fetch(FetchDescriptor<Home>()) {
            digest.append("H \(home.id) \(home.latitude) \(home.longitude) \(home.radiusKm) "
                + "\(time(home.startedAt)) \(time(home.endedAt))")
        }
        for home in try context.fetch(FetchDescriptor<TemporaryHome>()) {
            digest.append("T \(home.id) \(home.latitude) \(home.longitude) \(home.radiusKm) "
                + "\(time(home.startedAt)) \(time(home.endedAt)) \(time(home.removedAt)) "
                + "\(home.coverageRevision)")
        }
        for override in try context.fetch(FetchDescriptor<HomeAreaOverride>()) {
            digest.append("O \(override.id) \(override.kindRaw) \(override.centerLatitude) "
                + "\(override.centerLongitude) \(override.radiusKm) "
                + "\(override.homeID?.uuidString ?? "-")")
        }
        return digest.sorted()
    }

    static func admit(
        _ evidence: [SharedPing], ownEvidence: [DateInterval],
        rings: [TripClassifier.HomeRing], existingIDs: Set<UUID>
    ) -> Admission {
        var admission = Admission()
        for ping in evidence {
            if existingIDs.contains(ping.id) {
                admission.alreadyPresent += 1
            } else if covers(ownEvidence, ping.timestamp) {
                admission.droppedForOwnEvidence += 1
            } else if TripShareExport.isInsideHome(
                ping.timestamp, latitude: ping.latitude, longitude: ping.longitude, rings: rings) {
                admission.droppedInsideHome += 1
            } else {
                admission.admitted.append(ping)
            }
        }
        return admission
    }
}

/// What one recording unit did with its batch.
nonisolated struct SharedUnitOutcome: Sendable, Equatable {
    var inserted: [UUID] = []
    var droppedForOwnEvidence = 0
    var droppedInsideHome = 0
    /// The Homes, temporary homes or corrections changed since the rings
    /// were read: nothing was written, and the caller reads them again.
    var homesChanged = false
}

extension PingRecorder {

    /// One gate unit of shared fixes: skips ids already stored, admits the
    /// rest again against the store as it is now (the user's own evidence
    /// and home areas can arrive after the import's first read, and still
    /// win), records the admitted ones as `.sharedImport` under their own ids
    /// (the import path's dedup, hex upsert and pre-attach), saves, and
    /// returns what it inserted and dropped. `rings` must have been read
    /// after `homeDigest`; a digest that moved since writes nothing. The
    /// caller owns the gate.
    func recordSharedPings(
        _ batch: [ImportedPingCandidate], rings: [TripClassifier.HomeRing], homeDigest: [String]
    ) throws -> SharedUnitOutcome {
        guard try SharedTripImportPlan.homeDependencyDigest(in: modelContext) == homeDigest else {
            return SharedUnitOutcome(homesChanged: true)
        }
        let ids = batch.compactMap(\.id)
        var existing = Set<UUID>()
        for start in stride(from: 0, to: ids.count, by: 500) {
            let slice = Array(ids[start..<min(start + 500, ids.count)])
            var descriptor = FetchDescriptor<LocationPing>(predicate: #Predicate { slice.contains($0.id) })
            descriptor.propertiesToFetch = [\.id]
            existing.formUnion(try modelContext.fetch(descriptor).map(\.id))
        }
        let fresh = batch.filter { $0.id.map { !existing.contains($0) } ?? false }
        var outcome = SharedUnitOutcome()
        guard let first = fresh.map(\.timestamp).min(), let last = fresh.map(\.timestamp).max() else {
            return outcome
        }
        let own = try SharedTripImportPlan.ownEvidenceIntervals(
            in: modelContext, from: first, to: last, padding: SharedTripImportPlan.ownEvidencePadding)
        var admitted: [ImportedPingCandidate] = []
        for candidate in fresh {
            if SharedTripImportPlan.covers(own, candidate.timestamp) {
                outcome.droppedForOwnEvidence += 1
            } else if TripShareExport.isInsideHome(
                candidate.timestamp, latitude: candidate.latitude, longitude: candidate.longitude,
                rings: rings) {
                outcome.droppedInsideHome += 1
            } else {
                admitted.append(candidate)
            }
        }
        guard !admitted.isEmpty else { return outcome }
        _ = try recordImportedPings(admitted, source: .sharedImport)
        let wanted = Set(admitted.compactMap(\.id))
        outcome.inserted = modelContext.insertedModelsArray.compactMap { ($0 as? LocationPing)?.id }
            .filter { wanted.contains($0) }
        try saveImportBatch()
        return outcome
    }

    /// The home digest outside any unit, read before the rings it vouches for.
    func sharedImportHomeDigest() throws -> [String] {
        try SharedTripImportPlan.homeDependencyDigest(in: modelContext)
    }
}
