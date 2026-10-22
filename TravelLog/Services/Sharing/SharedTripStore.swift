//
//  SharedTripStore.swift
//  TravelLog
//
//  Recipient side, the store part: the reads the import plan needs, the
//  sender's-name carry after the pipeline, and "Remove Shared Data". Writes
//  run inside one `PipelineGate.shared` unit each (the caller holds it); no
//  model or context leaves this actor.
//

import CoreLocation
import Foundation
import SwiftData
import os.log

@ModelActor
actor SharedTripStore {

    private var logger: Logger { Logger(subsystem: "com.travellog.app", category: "SharedTripStore") }

    enum StoreError: Error { case incompleteLocalData }

    // MARK: - Reads

    /// The instants near this user's own evidence between `start` and `end`:
    /// every ping, stay and Visit that is not shared, padded each side.
    func ownEvidenceIntervals(
        from start: Date, to end: Date, padding: TimeInterval
    ) throws -> [DateInterval] {
        try SharedTripImportPlan.ownEvidenceIntervals(
            in: modelContext, from: start, to: end, padding: padding)
    }

    func existingPingIDs(_ ids: [UUID]) throws -> Set<UUID> {
        var found = Set<UUID>()
        for start in stride(from: 0, to: ids.count, by: 500) {
            let slice = Array(ids[start..<min(start + 500, ids.count)])
            var descriptor = FetchDescriptor<LocationPing>(predicate: #Predicate { slice.contains($0.id) })
            descriptor.propertiesToFetch = [\.id]
            found.formUnion(try modelContext.fetch(descriptor).map(\.id))
        }
        return found
    }

    /// The ids of the trips whose stays hold any of `pingIDs`.
    func tripsHolding(pingIDs: Set<UUID>) throws -> Set<UUID> {
        Set(try stays(holding: pingIDs).compactMap { $0.trip?.id })
    }

    private func stays(holding pingIDs: Set<UUID>) throws -> [Stay] {
        guard !pingIDs.isEmpty else { return [] }
        // Shared fixes cluster into shared stays or join a merged one, but a
        // stay's tag can trail what it holds (a photo stay that took a shared
        // fix before absorption marked such hosts mixed): look at every stay.
        var descriptor = FetchDescriptor<Stay>()
        descriptor.propertiesToFetch = [\.pingIDsString]
        return try modelContext.fetch(descriptor)
            .filter { !$0.isDeleted && $0.pingIDs.contains(where: pingIDs.contains) }
    }

    // MARK: - Name carry

    /// After the pipeline: when exactly one physical trip row holds the
    /// shared stays, gives it the sender's name unless the user named it
    /// themselves (a name other than the one this share put there). A UUID
    /// twin that holds none of them is not that trip and is never written;
    /// twins that both hold some leave the target unclear, so nothing is
    /// written until they converge. A name this share put on another trip,
    /// still unchanged, is taken back. Returns the trip and name the ledger
    /// should remember; a user's rename forgets both.
    func carrySenderName(
        _ name: String?, pingIDs: Set<UUID>,
        previouslyApplied: String?, previousTripID: UUID?
    ) throws -> (tripID: UUID?, appliedName: String?) {
        let name = TripTitleStore.normalized(name)
        var holders: [PersistentIdentifier: Trip] = [:]
        for stay in try stays(holding: pingIDs) {
            if let trip = stay.trip, !trip.isDeleted { holders[trip.persistentModelID] = trip }
        }
        guard holders.count == 1, let target = holders.values.first else {
            return (previousTripID, previouslyApplied)
        }
        let tripID = target.id
        var changed = false
        if let previousTripID, previousTripID != tripID, let previouslyApplied {
            for trip in try trips(id: previousTripID)
            where TripTitleStore.normalized(trip.customName) == previouslyApplied {
                trip.customName = nil
                changed = true
            }
        }
        var result: (tripID: UUID?, appliedName: String?) = (tripID, name)
        let current = TripTitleStore.normalized(target.customName)
        if let current, current != previouslyApplied {
            // The user's own name. Never overwritten.
            result = (nil, nil)
        } else if current != name {
            target.customName = name
            changed = true
        }
        if changed {
            do { try modelContext.save() } catch {
                modelContext.rollback()
                throw error
            }
        }
        return result
    }

    /// What a rebuilt stay's place or window no longer supports. A stay that
    /// left its res-6 cell loses its place names, which the stay geocoding
    /// drain names again (country and ISO code stay, so no summary loses a
    /// country meanwhile), and an imported stay's zone is derived again from
    /// its new longitude (a live stay's zone was the device's, there). A moved
    /// window drops its step count. The leg into the stay, and the leg out of
    /// it into the next stay, were measured from the old place and times:
    /// both are cleared for the transit drain, keeping the user's Not a
    /// Flight with its distance, as the clusterer does.
    private func clearDerivedFields(of stay: Stay, cell: String, start: Date, end: Date) throws {
        let leftCell = stay.h3IndexRes6 != cell
        if leftCell {
            stay.locality = nil
            stay.subLocality = nil
            stay.metroName = nil
            stay.islandName = nil
            stay.administrativeArea = nil
            if !stay.source.isLiveObservation, stay.source != .merged {
                stay.timeZoneIdentifier = StayTimeZone.identifier(
                    for: stay.source, longitude: stay.centroidLongitude,
                    isoCountryCode: stay.isoCountryCode, at: stay.startTime)
            }
        }
        let startMoved = abs(stay.startTime.timeIntervalSince(start)) >= 60
        let endMoved = abs(stay.endTime.timeIntervalSince(end)) >= 60
        if startMoved || endMoved { stay.stepsWalked = nil }
        let notFlight = TransitMode.notFlight.rawValue
        if leftCell || startMoved, stay.transitFromPreviousRaw != notFlight {
            stay.transitFromPreviousRaw = nil
            stay.distanceFromPreviousKm = nil
        }
        guard leftCell || endMoved else { return }
        let id = stay.id
        var descriptor = FetchDescriptor<Stay>(
            predicate: #Predicate { $0.startTime >= end && $0.id != id },
            sortBy: [SortDescriptor(\.startTime, order: .forward)])
        descriptor.fetchLimit = 1
        for successor in try modelContext.fetch(descriptor)
        where !successor.isDeleted && successor.transitFromPreviousRaw != notFlight {
            successor.transitFromPreviousRaw = nil
            successor.distanceFromPreviousKm = nil
        }
    }

    private func trips(id: UUID) throws -> [Trip] {
        try modelContext.fetch(FetchDescriptor<Trip>(predicate: #Predicate { $0.id == id }))
            .filter { !$0.isDeleted }
    }

    // MARK: - Remove Shared Data

    struct Removal: Sendable {
        var deletedPings = 0
        var deletedStayIDs: Set<UUID> = []
    }

    /// Deletes the `.sharedImport` pings among `pingIDs`, rebuilds or deletes
    /// the stays they were in, repairs the map cells they marked, refreshes
    /// or deletes the trips that held those stays, and takes back the name
    /// the share carried while the trip still shows it. One save; a failed
    /// read or an incomplete stay rolls everything back.
    func removeSharedEvidence(
        pingIDs: Set<UUID>, appliedName: String?, namedTripID: UUID?
    ) throws -> Removal {
        do {
            return try removeSharedEvidenceTransaction(
                pingIDs: pingIDs, appliedName: appliedName, namedTripID: namedTripID)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func removeSharedEvidenceTransaction(
        pingIDs: Set<UUID>, appliedName: String?, namedTripID: UUID?
    ) throws -> Removal {
        var removal = Removal()
        let shared = DataSource.sharedImport.rawValue
        let ids = Array(pingIDs)
        var sharedPings: [LocationPing] = []
        for start in stride(from: 0, to: ids.count, by: 500) {
            let slice = Array(ids[start..<min(start + 500, ids.count)])
            sharedPings += try modelContext.fetch(FetchDescriptor<LocationPing>(predicate: #Predicate {
                slice.contains($0.id) && $0.sourceRaw == shared
            }))
        }
        let removedIDs = Set(sharedPings.map(\.id))

        var parents: [ObjectIdentifier: TripTitleStore.ParentSemanticSnapshot] = [:]
        func markParent(_ trip: Trip?) {
            guard let trip, parents[ObjectIdentifier(trip)] == nil else { return }
            parents[ObjectIdentifier(trip)] = TripTitleStore.ParentSemanticSnapshot(
                trip: trip, semantic: TripTitleStore.semanticSnapshot(for: trip))
        }

        // Stays: rebuild each from the evidence it keeps, validated before
        // the first change.
        let holders = try stays(holding: removedIDs)
        let keptIDs = Array(Set(holders.flatMap(\.pingIDs)).subtracting(removedIDs))
        var keptPings: [UUID: StayGeometryPing] = [:]
        for start in stride(from: 0, to: keptIDs.count, by: 500) {
            let slice = Array(keptIDs[start..<min(start + 500, keptIDs.count)])
            for ping in try modelContext.fetch(FetchDescriptor<LocationPing>(predicate: #Predicate {
                slice.contains($0.id)
            })) {
                keptPings[ping.id] = StayGeometryPing(
                    timestamp: ping.timestamp, latitude: ping.latitude,
                    longitude: ping.longitude, sourceRaw: ping.sourceRaw)
            }
        }
        let holderIDs = Set(holders.map(\.id))
        var visitsByStay: [UUID: [StayGeometryVisit]] = [:]
        if !holderIDs.isEmpty {
            for visit in try modelContext.fetch(FetchDescriptor<Visit>(predicate: #Predicate { $0.stayID != nil })) {
                guard let stayID = visit.stayID, holderIDs.contains(stayID) else { continue }
                visitsByStay[stayID, default: []].append(StayGeometryVisit(
                    id: visit.id, arrivalDate: visit.arrivalDate, departureDate: visit.departureDate,
                    latitude: visit.latitude, longitude: visit.longitude,
                    horizontalAccuracy: visit.horizontalAccuracy, receivedAt: visit.receivedAt))
            }
        }
        var repairs: [(stay: Stay, remaining: [UUID], geometry: StayGeometry?)] = []
        for stay in holders {
            let remaining = stay.pingIDs.filter { !removedIDs.contains($0) }
            var pings: [StayGeometryPing] = []
            for id in remaining {
                // A stay whose other fixes have not arrived yet cannot be
                // rebuilt honestly: fail closed, a retry can finish it.
                guard let ping = keptPings[id] else { throw StoreError.incompleteLocalData }
                pings.append(ping)
            }
            pings.sort { $0.timestamp < $1.timestamp }
            let geometry = StayGeometry.recompute(
                from: pings, visits: visitsByStay[stay.id] ?? [],
                earliestAllowedStart: nil, latestAllowedEnd: nil)
            if geometry == nil, !(remaining.isEmpty && (visitsByStay[stay.id] ?? []).isEmpty) {
                throw StoreError.incompleteLocalData
            }
            repairs.append((stay, remaining, geometry))
        }
        var moved: [(stay: Stay, inputs: StayClassificationInputs)] = []
        for repair in repairs {
            let stay = repair.stay
            markParent(stay.trip)
            guard let geometry = repair.geometry,
                  let h3 = H3Service.cellIndex(latitude: geometry.centroidLatitude,
                                               longitude: geometry.centroidLongitude) else {
                // Detach first so no inverse array still shows it.
                stay.trip = nil
                removal.deletedStayIDs.insert(stay.id)
                modelContext.delete(stay)
                continue
            }
            let weatherKey = WeatherEnricher.WeatherValidityKey(stay)
            let inputs = StayClassificationInputs(stay)
            let before = (cell: stay.h3IndexRes6, start: stay.startTime, end: stay.endTime)
            stay.pingIDs = repair.remaining
            stay.pingCount = repair.remaining.count
            stay.startTime = geometry.startTime
            stay.endTime = geometry.endTime
            stay.durationMinutes = geometry.durationMinutes
            stay.centroidLatitude = geometry.centroidLatitude
            stay.centroidLongitude = geometry.centroidLongitude
            stay.h3IndexRes6 = h3
            stay.isAirport = AirportDetector.shared.isNearAirport(CLLocationCoordinate2D(
                latitude: geometry.centroidLatitude, longitude: geometry.centroidLongitude))
            stay.sourceRaw = geometry.sourceRaw
            WeatherEnricher.clearWeatherIfKeyChanged(stay, from: weatherKey)
            try clearDerivedFields(of: stay, cell: before.cell, start: before.start, end: before.end)
            moved.append((stay, inputs))
        }
        // After every deletion above, so a stay leaving its trip never takes
        // the last member a deleted one left behind.
        var detached: [UUID: Set<UUID>] = [:]
        for (stay, inputs) in moved {
            StayClassificationInputs.resetIfMoved(stay, from: inputs, detached: &detached)
        }

        // Map cells: the import only ever widened their windows, so the
        // photo discard's rule applies unchanged, including its refusal to
        // delete or rebuild a row in a synced store.
        let affectedCells = Set(sharedPings.map(\.h3IndexRes6)).filter { !$0.isEmpty }
        var importFirst: [String: Date] = [:]
        var importLast: [String: Date] = [:]
        for ping in sharedPings where !ping.h3IndexRes6.isEmpty {
            importFirst[ping.h3IndexRes6] = min(importFirst[ping.h3IndexRes6] ?? ping.timestamp, ping.timestamp)
            importLast[ping.h3IndexRes6] = max(importLast[ping.h3IndexRes6] ?? ping.timestamp, ping.timestamp)
        }
        for ping in sharedPings { modelContext.delete(ping) }
        removal.deletedPings = sharedPings.count
        if !affectedCells.isEmpty {
            var descriptor = FetchDescriptor<LocationPing>(sortBy: [SortDescriptor(\.timestamp)])
            descriptor.propertiesToFetch = [\.id, \.timestamp, \.h3IndexRes6]
            var first: [String: Date] = [:]
            var last: [String: Date] = [:]
            var count: [String: Int] = [:]
            var previousCell: String?
            for ping in try modelContext.fetch(descriptor) where !removedIDs.contains(ping.id) {
                let cell = ping.h3IndexRes6
                if affectedCells.contains(cell) {
                    if first[cell] == nil { first[cell] = ping.timestamp }
                    last[cell] = ping.timestamp
                    if cell != previousCell { count[cell, default: 0] += 1 }
                }
                previousCell = cell
            }
            let evidenceIsLocal = PhotoImportService.hexEvidenceIsLocal(modelContainer)
            for cell in affectedCells {
                let key = cell
                for row in try modelContext.fetch(FetchDescriptor<HexVisit>(predicate: #Predicate { $0.h3Index == key })) {
                    switch PhotoImportService.hexVisitRepairAction(
                        rowFirstVisited: row.firstVisited, rowLastVisited: row.lastVisited,
                        importFirst: importFirst[cell] ?? .distantFuture,
                        importLast: importLast[cell] ?? .distantPast,
                        survivingFirst: first[cell], survivingLast: last[cell],
                        localEvidenceIsComplete: evidenceIsLocal) {
                    case .recompute(let firstVisited, let lastVisited):
                        row.firstVisited = firstVisited
                        row.lastVisited = lastVisited
                        let localOnly = firstVisited == first[cell] && lastVisited == last[cell]
                        row.visitCount = localOnly ? max(1, count[cell] ?? 1) : max(1, row.visitCount)
                    case .keep:
                        continue
                    case .delete:
                        modelContext.delete(row)
                    }
                }
            }
        }

        // Trips: dates and summary from the stays they keep; an emptied trip
        // goes, with photo choices no populated twin still owns.
        let allTrips = try modelContext.fetch(FetchDescriptor<Trip>())
        var deletedTripRows: Set<PersistentIdentifier> = []
        var deletedTripIDs: Set<UUID> = []
        for snapshot in parents.values {
            let trip = snapshot.trip
            guard !trip.isDeleted else { continue }
            let remaining = trip.orderedStays.filter { !$0.isDeleted }
            guard let firstStay = remaining.first else {
                deletedTripRows.insert(trip.persistentModelID)
                deletedTripIDs.insert(trip.id)
                modelContext.delete(trip)
                continue
            }
            trip.startDate = remaining.map(\.startTime).min() ?? firstStay.startTime
            if trip.isComplete, trip.endDate != nil {
                trip.endDate = remaining.map(\.endTime).max()
            }
            trip.recomputeSummary()
            if snapshot.semantic != TripTitleStore.semanticSnapshot(for: trip) {
                TripTitleStore.invalidateGeneratedTitles(for: trip, in: modelContext)
            }
        }
        let populatedSurvivors = Set(allTrips.filter { trip in
            !deletedTripRows.contains(trip.persistentModelID) && !trip.isDeleted
                && (trip.stays ?? []).contains { !$0.isDeleted }
        }.map(\.id))
        for tripID in deletedTripIDs.subtracting(populatedSurvivors) {
            let id = tripID
            for row in try modelContext.fetch(FetchDescriptor<HiddenPhoto>(predicate: #Predicate { $0.tripID == id })) {
                modelContext.delete(row)
            }
            for row in try modelContext.fetch(FetchDescriptor<PinnedPhoto>(predicate: #Predicate { $0.tripID == id })) {
                modelContext.delete(row)
            }
        }

        // The sender's name goes with their evidence, unless the user renamed.
        if let namedTripID, let appliedName {
            for trip in try trips(id: namedTripID)
            where TripTitleStore.normalized(trip.customName) == appliedName {
                trip.customName = nil
            }
        }

        if modelContext.hasChanges { try modelContext.save() }
        PhotoLineageStore.recordDetachedMembers(detached, defaults: PhotoLineageStore.recorderDefaults)
        logger.info("Removed \(removal.deletedPings) shared ping(s) and \(removal.deletedStayIDs.count) stay(s).")
        return removal
    }
}
