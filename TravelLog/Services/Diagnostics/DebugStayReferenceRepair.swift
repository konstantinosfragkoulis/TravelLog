//
//  DebugStayReferenceRepair.swift
//  TravelLog
//
//  DEBUG-build-only repair for stays whose `pingIDs` reference LocationPing
//  rows that no longer exist in the local store.
//
//  Earlier discard teardowns stripped photo-import ping IDs from `.merged`
//  hosts only, so a `.jsonImport`/`.timelineImport`/`.gpxImport` host stay kept
//  UUIDs of rows the discard then deleted. The fail-closed discard preflight
//  refuses to run while such a reference shares a stay with a current photo
//  import ("incompleteLocalData"), because on a partially hydrated CloudKit
//  store a locally missing row is not proof of deletion.
//
//  That is exactly why this repair is MANUAL and confirmation-gated: only
//  the user can assert "iCloud sync is complete on this device, the missing
//  rows are damage, not latency." It must never run automatically.
//
//  Repair semantics deliberately mirror the discard teardown's host repair:
//  strip the unresolvable references, then rebuild time bounds, duration,
//  dateline-safe centroid, H3 cell, airport flag, and provenance from the
//  surviving pings and Visits via the same `StayGeometry` path teardown uses —
//  the two can never disagree on the math. `category`, `userOverridden`,
//  and `distanceFromHomeKm` are preserved, matching the teardown rule.
//

#if DEBUG

import CoreLocation
import Foundation
import SwiftData

@ModelActor
actor DebugStayReferenceRepair {

    struct Report: Sendable, Equatable {
        /// Stays with referenced pings or linked Visit evidence.
        var scannedStays = 0
        var staysWithDanglingReferences = 0
        var danglingReferences = 0
        /// Scan mode: stays that WOULD be repaired. Apply mode: repaired.
        var repairedStays = 0
        /// Every referenced ping is missing and there is no linked Visit
        /// evidence, so the row is reported and left untouched.
        var skippedNoSurvivingPings = 0
        /// Duplicate ping copies disagree on immutable fields, or survivors
        /// cannot produce valid geometry. Left untouched (teardown rule:
        /// never pick an arbitrary copy and sync fabricated data).
        var skippedInconsistent = 0
        var updatedTrips = 0
        /// Non-nil when a fetch/save failed; the context was rolled back and
        /// nothing was persisted.
        var errorDescription: String?
    }

    /// Read-only dry run: same decisions as `repair()`, zero mutation.
    func scan() -> Report {
        run(apply: false)
    }

    /// Apply the repair in one atomic save. Callers wrap this in a
    /// `PipelineGate` unit touching `[.stay, .trip]`.
    func repair() -> Report {
        run(apply: true)
    }

    private func run(apply: Bool) -> Report {
        var report = Report()
        do {
            try runThrowing(apply: apply, report: &report)
        } catch {
            modelContext.rollback()
            report.errorDescription = String(describing: error)
        }
        return report
    }

    private func runThrowing(apply: Bool, report: inout Report) throws {
        let allPings = try modelContext.fetch(FetchDescriptor<LocationPing>())
        var snapshotsByID: [UUID: StayGeometryPing] = [:]
        var inconsistentIDs: Set<UUID> = []
        snapshotsByID.reserveCapacity(allPings.count)
        for ping in allPings {
            let snapshot = StayGeometryPing(
                timestamp: ping.timestamp,
                latitude: ping.latitude,
                longitude: ping.longitude,
                sourceRaw: ping.sourceRaw
            )
            if let existing = snapshotsByID[ping.id], existing != snapshot {
                inconsistentIDs.insert(ping.id)
            }
            snapshotsByID[ping.id] = snapshot
        }

        let allVisits = try modelContext.fetch(FetchDescriptor<Visit>())
        var visitsByStayID: [UUID: [StayGeometryVisit]] = [:]
        for visit in allVisits {
            guard let stayID = visit.stayID else { continue }
            visitsByStayID[stayID, default: []].append(StayGeometryVisit(
                id: visit.id,
                arrivalDate: visit.arrivalDate,
                departureDate: visit.departureDate,
                latitude: visit.latitude,
                longitude: visit.longitude,
                horizontalAccuracy: visit.horizontalAccuracy,
                receivedAt: visit.receivedAt
            ))
        }

        let stays = try modelContext.fetch(FetchDescriptor<Stay>())
        // Physical parents, captured before their stays change. They drive the
        // bounds refresh too, so a UUID twin never stands in for the repaired row.
        var titleSnapshots: [ObjectIdentifier: TripTitleStore.ParentSemanticSnapshot] = [:]
        for stay in stays {
            let originalIDs = stay.pingIDs
            let visitEvidence = visitsByStayID[stay.id] ?? []
            guard !originalIDs.isEmpty || !visitEvidence.isEmpty else { continue }
            report.scannedStays += 1

            let surviving = originalIDs.filter { snapshotsByID[$0] != nil }
            guard surviving.count != originalIDs.count else { continue }
            report.staysWithDanglingReferences += 1
            report.danglingReferences += originalIDs.count - surviving.count

            guard !surviving.isEmpty || !visitEvidence.isEmpty else {
                report.skippedNoSurvivingPings += 1
                continue
            }
            guard !surviving.contains(where: { inconsistentIDs.contains($0) }) else {
                report.skippedInconsistent += 1
                continue
            }
            let survivingPings = surviving.compactMap { snapshotsByID[$0] }
            let previous = try StayClusterer.previousStay(in: modelContext, before: stay.startTime, excluding: stay.id)
            let next = try StayClusterer.nextStay(in: modelContext, after: stay.startTime, excluding: stay.id)
            guard let geometry = StayGeometry.recompute(
                from: survivingPings,
                visits: visitEvidence,
                earliestAllowedStart: previous?.endTime.addingTimeInterval(1),
                latestAllowedEnd: next?.startTime.addingTimeInterval(-1)
            ),
                  let h3Index = H3Service.cellIndex(
                    latitude: geometry.centroidLatitude,
                    longitude: geometry.centroidLongitude
                  )
            else {
                report.skippedInconsistent += 1
                continue
            }

            report.repairedStays += 1
            guard apply else { continue }

            if let trip = stay.trip, titleSnapshots[ObjectIdentifier(trip)] == nil {
                titleSnapshots[ObjectIdentifier(trip)] = TripTitleStore.ParentSemanticSnapshot(
                    trip: trip, semantic: TripTitleStore.semanticSnapshot(for: trip))
            }
            let weatherKey = WeatherEnricher.WeatherValidityKey(stay)
            stay.pingIDs = surviving
            stay.pingCount = surviving.count
            stay.startTime = geometry.startTime
            stay.endTime = geometry.endTime
            stay.durationMinutes = geometry.durationMinutes
            stay.centroidLatitude = geometry.centroidLatitude
            stay.centroidLongitude = geometry.centroidLongitude
            stay.h3IndexRes6 = h3Index
            stay.isAirport = AirportDetector.shared.isNearAirport(
                CLLocationCoordinate2D(
                    latitude: geometry.centroidLatitude,
                    longitude: geometry.centroidLongitude
                )
            )
            stay.sourceRaw = geometry.sourceRaw
            WeatherEnricher.clearWeatherIfKeyChanged(stay, from: weatherKey)
        }

        guard apply else { return }

        // Shrunk stay windows can shrink the containing trip's bounds.
        // No stay joins or leaves a trip here, so an empty trip is impossible;
        // summaries and titles are refreshed below when their semantic inputs changed.
        for snapshot in titleSnapshots.values {
            let trip = snapshot.trip
            guard !trip.isDeleted else { continue }
            let remaining = trip.orderedStays.filter { !$0.isDeleted }
            guard let first = remaining.first, let last = remaining.last else { continue }
            trip.startDate = first.startTime
            if trip.isComplete, trip.endDate != nil {
                trip.endDate = last.endTime
            }
            report.updatedTrips += 1
        }
        try TripTitleStore.invalidateChangedParentTitles(
            from: Array(titleSnapshots.values), in: modelContext)

        try modelContext.save()
    }
}

#endif
