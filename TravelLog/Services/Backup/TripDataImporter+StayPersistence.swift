//
//  TripDataImporter+StayPersistence.swift
//  TravelLog
//

import Foundation
import SwiftData
import CoreLocation
import os.log

extension TripDataImporter {

    func pendingGeocodes() -> [PendingGeocode] { pendingGeocodeSnapshots }

    #if DEBUG
    /// Heals the first row with `stayID` as the store holds it now.
    func applyGeocodeHealForTesting(
        stayID: UUID,
        result: GeocodeResolver.Result
    ) -> Int {
        let context = ModelContext(modelContainer)
        guard let stay = try? context.fetch(FetchDescriptor<Stay>(
            predicate: #Predicate { $0.id == stayID })).first else { return 0 }
        return applyGeocodeHeals([(PendingGeocode(stay), result)])
    }

    func applyGeocodeHealForTesting(
        _ witness: PendingGeocode,
        result: GeocodeResolver.Result
    ) -> Int {
        applyGeocodeHeals([(witness, result)])
    }
    #endif

    /// Phase 2 of a restore: heal the offline place layers for the
    /// just-inserted stays WITHOUT any gate unit spanning the geocode
    /// awaits. Gate discipline lives INSIDE this method (the
    /// `TransitInferer.recorroborateUnknownLegs` shape): resolution runs
    /// ungated against the offline resolver, and writes land through
    /// short per-chunk gate units that re-read each witnessed row and
    /// re-validate it (`PendingGeocode.matches`) — so a queued background
    /// SLC wake-ping save can interleave between chunks. Callers must invoke
    /// this OUTSIDE any PipelineGate unit (the gate is non-reentrant).
    /// Returns the number of stays healed.
    @discardableResult
    func healPendingGeocodes(
        _ pending: [PendingGeocode], gate: PipelineGate = .shared
    ) async -> Int {
        guard !pending.isEmpty else { return 0 }

        // Ungated resolution phase. Each answer travels with the witness it
        // was resolved for, re-checked at apply time; a resolver miss
        // (remote area) leaves the nils — idempotent.
        var resolutions: [(witness: PendingGeocode, result: GeocodeResolver.Result)] = []
        for snapshot in pending {
            if let r = await GeocodeResolver.shared.resolve(
                latitude: snapshot.latitude, longitude: snapshot.longitude
            ) {
                resolutions.append((snapshot, r))
            }
        }
        guard !resolutions.isEmpty else { return 0 }

        var healed = 0
        let chunkSize = 25
        var index = 0
        while index < resolutions.count {
            let chunk = Array(resolutions[index ..< min(index + chunkSize, resolutions.count)])
            index += chunk.count
            healed += await gate.runReturning(touching: [.stay, .trip]) {
                await self.applyGeocodeHeals(chunk)
            }
        }
        return healed
    }

    /// Gated apply for one heal chunk: re-read each witnessed physical row,
    /// apply only where it still matches its witness (another lane may have
    /// moved, replaced, geocoded or deleted it while no gate was held; a
    /// same-id twin is another row), write, refresh affected trip summaries,
    /// save once. The rows are read in a fresh context: this actor's own
    /// keeps the rows it inserted cached, so a centroid another context
    /// moved since could still read as the witnessed one there.
    private func applyGeocodeHeals(
        _ chunk: [(witness: PendingGeocode, result: GeocodeResolver.Result)]
    ) -> Int {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let ids = Array(Set(chunk.map(\.witness.stayID)))
        let predicate = #Predicate<Stay> { ids.contains($0.id) }
        // A failed read heals nothing: the stays keep their nils.
        guard let fetched = try? context.fetch(FetchDescriptor<Stay>(predicate: predicate)) else {
            return 0
        }
        let staysByRow = Dictionary(
            fetched.map { ($0.persistentModelID, $0) }, uniquingKeysWith: { first, _ in first })
        var healed = 0
        var titleSnapshots:
            [ObjectIdentifier: TripTitleStore.ParentSemanticSnapshot] = [:]
        for (witness, r) in chunk {
            guard let stay = staysByRow[witness.persistentID], witness.matches(stay) else {
                continue
            }
            if let trip = stay.trip {
                let identity = ObjectIdentifier(trip)
                if titleSnapshots[identity] == nil {
                    titleSnapshots[identity] =
                        TripTitleStore.ParentSemanticSnapshot(
                            trip: trip,
                            semantic: TripTitleStore.semanticSnapshot(for: trip))
                }
            }
            if stay.locality == nil, r.bestLocalityName != nil {
                stay.locality = r.localityForStorage
            }
            stay.administrativeArea = r.administrativeArea
            stay.metroName = r.metroName
            stay.islandName = r.islandName
            stay.subLocality = stay.subLocality ?? r.subLocalityName
            stay.country = stay.country ?? r.country
            stay.isoCountryCode = stay.isoCountryCode ?? r.isoCountryCode
            healed += 1
        }
        guard healed > 0 else { return 0 }
        // Refresh every healed parent, even with unchanged title inputs;
        // imports may keep a summary built without the home-place filter.
        // A parent owed a later pass (`TripTitleStore.mayDeriveSummary`) keeps it.
        let hydrating = TripTitleStore.storeMayBeHydrating()
        for snapshot in titleSnapshots.values {
            let trip = snapshot.trip
            guard !trip.isDeleted,
                  snapshot.semantic == TripTitleStore.semanticSnapshot(for: trip) else {
                continue
            }
            guard TripTitleStore.mayDeriveSummary(
                holdsNamedStays: TripTitleStore.heldItsNamedStays(snapshot),
                storeMayBeHydrating: hydrating) else {
                TripTitleStore.oweSummaryRefresh()
                continue
            }
            trip.recomputeSummary()
        }
        _ = try? TripTitleStore.invalidateChangedParentTitles(
            from: Array(titleSnapshots.values), in: context)
        do {
            try context.save()
        } catch {
            context.rollback()
            logger.error("JSON import geocode heal save failed: \(error.localizedDescription)")
            return 0
        }
        return healed
    }

    /// A restored stay's airport flag. Derived, so stamped from the restored
    /// centroid with the bundled dataset, as live clustering and import
    /// attachment do: a backup made before an airport joined the dataset
    /// carries a stale false, and the one-shot airport backfill is latched on
    /// a used device. The file's flag stands only when the dataset did not load.
    func restoredIsAirport(_ importedStay: ImportedStay) -> Bool {
        AirportDetector.shared.airportCount > 0
            ? AirportDetector.shared.isNearAirport(CLLocationCoordinate2D(
                latitude: importedStay.centroidLatitude, longitude: importedStay.centroidLongitude))
            : importedStay.isAirport
    }

    /// Builds and inserts one restored stay as it was stored, without trip
    /// linking: shared by the per-trip loop and the tripless loop so the two
    /// paths cannot drift. `isAirport` is stamped from the bundled airports,
    /// and a stay with no offline place layers is queued for the heal.
    func insertImportedStay(
        _ importedStay: ImportedStay, h3Index: String, retainedRevisions: [UUID: Int]
    ) -> Stay {
        let stay = Stay(
            startTime: importedStay.startTime,
            endTime: importedStay.endTime,
            centroidLatitude: importedStay.centroidLatitude,
            centroidLongitude: importedStay.centroidLongitude,
            h3IndexRes6: h3Index,
            pingCount: importedStay.pingCount,
            distanceFromHomeKm: importedStay.distanceFromHomeKm,
            pingIDs: [],
            source: .liveSLC,
            timeZoneIdentifier: importedStay.timeZoneIdentifier)
        stay.id = importedStay.id
        stay.sourceRaw = importedStay.sourceRaw
        stay.durationMinutes = importedStay.durationMinutes
        stay.pingIDsString = importedStay.pingIDsString
        if StayCategory(rawValue: importedStay.categoryRaw) != nil {
            stay.categoryRaw = importedStay.categoryRaw
        }
        // Provenance describes a home stamp; any other stay takes none. Its
        // revision rides with it, clamped to the declaration this import
        // keeps (`retainedTemporaryHomeRevisions`).
        if stay.category == .home, let id = importedStay.temporaryHomeID {
            let revision = importedStay.temporaryHomeRevision.map { revision in
                retainedRevisions[id].map { min(revision, $0) } ?? revision
            }
            stay.setTemporaryHomeProvenance(id, revision: revision)
        }
        stay.userOverridden = importedStay.userOverridden
        stay.continuesPreviousTrip = importedStay.continuesPreviousTrip
        stay.orderInTrip = importedStay.orderInTrip
        stay.isAirport = restoredIsAirport(importedStay)
        stay.locality = importedStay.locality
        stay.country = importedStay.country
        stay.isoCountryCode = importedStay.isoCountryCode
        stay.administrativeArea = importedStay.administrativeArea
        stay.subLocality = importedStay.subLocality
        stay.metroName = importedStay.metroName
        stay.islandName = importedStay.islandName
        stay.transitFromPreviousRaw = importedStay.transitFromPreviousRaw
        stay.distanceFromPreviousKm = importedStay.distanceFromPreviousKm
        stay.stepsWalked = importedStay.stepsWalked
        stay.weatherConditionRaw = importedStay.weatherConditionRaw
        stay.avgTemperatureC = importedStay.avgTemperatureC
        stay.precipitationMm = importedStay.precipitationMm
        stay.weatherData = importedStay.weatherData
        stay.dayKey = importedStay.dayKey
        // The one-shot geocoder backfills are LATCHED on any previously used
        // device, so a stay without place layers would keep them nil forever.
        // The heal itself runs AFTER the import's gate unit ends (per-stay
        // resolver awaits inside one held unit would starve queued SLC
        // wake-ping saves); here we only note the candidates. Their
        // witnesses are taken once a save commits them (`save()`): only then
        // is the row's id durable.
        if stay.administrativeArea == nil, stay.metroName == nil,
           stay.islandName == nil {
            unsavedGeocodeCandidates.append(stay)
        }
        modelContext.insert(stay)
        return stay
    }

    /// Restores the file's hex cells in this context: a cell id the store
    /// holds is left alone; a cell the store holds under another id absorbs
    /// the file's like the deduplicator does (earliest first entry, latest
    /// last, the larger re-entry count, nil place names filled), so its id is
    /// never rewritten; any other lands as stored. Throws on a failed lookup:
    /// treating it as absence would insert a duplicate of a cell the store
    /// holds. Returns how many cells landed or changed.
    func restoreHexVisits(_ cells: [ExportHexVisitSnapshot]) throws -> Int {
        guard !cells.isEmpty else { return 0 }
        #if DEBUG
        hexVisitFetchCallCountForTesting += 1
        if failingHexVisitFetchCallForTesting == hexVisitFetchCallCountForTesting {
            failingHexVisitFetchCallForTesting = nil
            throw CocoaError(.fileReadUnknown)
        }
        #endif
        let stored = try modelContext.fetch(FetchDescriptor<HexVisit>())
        let storedIDs = Set(stored.map(\.id))
        var byCell: [String: HexVisit] = [:]
        for row in stored.sorted(by: { $0.id.uuidString < $1.id.uuidString })
        where byCell[row.h3Index] == nil {
            byCell[row.h3Index] = row
        }
        var restored = 0
        var landedIDs = Set<UUID>()
        for cell in cells where !storedIDs.contains(cell.id) && landedIDs.insert(cell.id).inserted {
            if let row = byCell[cell.h3Index] {
                var changed = false
                if cell.firstVisited < row.firstVisited { row.firstVisited = cell.firstVisited; changed = true }
                if cell.lastVisited > row.lastVisited { row.lastVisited = cell.lastVisited; changed = true }
                if cell.visitCount > row.visitCount { row.visitCount = cell.visitCount; changed = true }
                if row.locality == nil, let locality = cell.locality { row.locality = locality; changed = true }
                if row.country == nil, let country = cell.country {
                    row.country = country
                    row.isoCountryCode = cell.isoCountryCode
                    changed = true
                }
                if changed { restored += 1 }
                continue
            }
            let row = HexVisit(
                h3Index: cell.h3Index, firstVisited: cell.firstVisited,
                centerLatitude: cell.centerLatitude, centerLongitude: cell.centerLongitude)
            row.id = cell.id
            row.lastVisited = cell.lastVisited
            row.visitCount = cell.visitCount
            row.locality = cell.locality
            row.country = cell.country
            row.isoCountryCode = cell.isoCountryCode
            modelContext.insert(row)
            byCell[cell.h3Index] = row
            restored += 1
        }
        return restored
    }

    /// Inserts the file's Wrapped recaps, planned trips and photo-import
    /// states whose ids the store lacks, as stored. A photo-import state
    /// lands only into a store holding none: it is one row per library, and
    /// the store's own row is this device's live import. Throws on a failed
    /// identity read. Returns how many rows landed.
    func restoreRecords(_ payload: ImportPayload) throws -> Int {
        var inserted = 0
        if !payload.yearWrapped.isEmpty {
            var known = try fetchExistingIDs(FetchDescriptor<YearWrapped>(), id: \.id)
            for record in payload.yearWrapped where known.insert(record.id).inserted {
                let row = YearWrapped(year: record.year)
                row.id = record.id
                row.generatedAt = record.generatedAt
                row.viewedAt = record.viewedAt
                row.statsData = record.statsData
                row.yearNarrative = record.yearNarrative
                row.yearNarrativeSourceRaw = record.yearNarrativeSourceRaw
                row.weatherCoverage = record.weatherCoverage
                row.transitCoverage = record.transitCoverage
                modelContext.insert(row)
                inserted += 1
            }
        }
        if !payload.plannedTrips.isEmpty {
            var known = try fetchExistingIDs(FetchDescriptor<PlannedTrip>(), id: \.id)
            for record in payload.plannedTrips where known.insert(record.id).inserted {
                let row = PlannedTrip(
                    eventExternalIdentifier: record.eventExternalIdentifier,
                    eventLocalIdentifier: record.eventLocalIdentifier,
                    title: record.title,
                    startDate: record.startDate, endDate: record.endDate,
                    isAllDay: record.isAllDay, locationText: record.locationText)
                row.id = record.id
                row.resolvedLatitude = record.resolvedLatitude
                row.resolvedLongitude = record.resolvedLongitude
                row.resolvedLocality = record.resolvedLocality
                row.resolvedCountry = record.resolvedCountry
                row.resolvedISOCountryCode = record.resolvedISOCountryCode
                row.distanceFromHomeKm = record.distanceFromHomeKm
                row.confidenceRaw = record.confidenceRaw
                row.signalsRaw = record.signalsRaw
                row.statusRaw = record.statusRaw
                row.matchedTripID = record.matchedTripID
                row.forecastWeatherData = record.forecastWeatherData
                row.createdAt = record.createdAt
                row.lastSeenAt = record.lastSeenAt
                modelContext.insert(row)
                inserted += 1
            }
        }
        if !payload.photoImportStates.isEmpty {
            let held = try fetchExistingIDs(FetchDescriptor<PhotoImportState>(), id: \.id)
            if held.isEmpty {
                var known = Set<UUID>()
                for record in payload.photoImportStates where known.insert(record.id).inserted {
                    let row = PhotoImportState(originDeviceID: record.originDeviceID)
                    row.id = record.id
                    row.startedAt = record.startedAt
                    row.completedAt = record.completedAt
                    row.statusRaw = record.statusRaw
                    row.totalAssetCount = record.totalAssetCount
                    row.processedAssetCount = record.processedAssetCount
                    row.acceptedPingCount = record.acceptedPingCount
                    row.watermarkCreationDate = record.watermarkCreationDate
                    row.watermarkLocalIdentifier = record.watermarkLocalIdentifier
                    row.lastError = record.lastError
                    row.lastUpdated = record.lastUpdated
                    row.cancelRequested = record.cancelRequested
                    modelContext.insert(row)
                    inserted += 1
                }
            }
        }
        return inserted
    }

    /// Inserts the file's pings the store lacks, as stored, one chunk per
    /// context and save: a 15-year history never sits in one context. A ping
    /// id already stored (or earlier in its chunk) is skipped; a later chunk
    /// sees an earlier one's saved rows. Pings link to nothing, so a chunk
    /// commits on its own; a re-import fills what a failed run left.
    func restorePings(_ section: BackupPingSection) -> (inserted: Int, failed: Bool) {
        var inserted = 0
        do {
            try section.forEachChunk { pings, _ in
                try autoreleasepool {
                    let context = ModelContext(modelContainer)
                    context.autosaveEnabled = false
                    let ids = pings.map(\.id)
                    var descriptor = FetchDescriptor<LocationPing>(
                        predicate: #Predicate { ids.contains($0.id) })
                    descriptor.propertiesToFetch = [\.id]
                    var known = Set(try context.fetch(descriptor).map(\.id))
                    var chunkInserted = 0
                    for ping in pings where known.insert(ping.id).inserted {
                        let row = LocationPing(
                            timestamp: ping.timestamp,
                            latitude: ping.latitude, longitude: ping.longitude,
                            horizontalAccuracy: ping.horizontalAccuracy,
                            h3IndexRes6: ping.h3IndexRes6,
                            altitude: ping.altitude,
                            verticalAccuracy: ping.verticalAccuracy)
                        row.id = ping.id
                        row.locality = ping.locality
                        row.subLocality = ping.subLocality
                        row.administrativeArea = ping.administrativeArea
                        row.country = ping.country
                        row.isoCountryCode = ping.isoCountryCode
                        row.isGeocoded = ping.isGeocoded
                        row.isProcessed = ping.isProcessed
                        row.sourceRaw = ping.sourceRaw
                        context.insert(row)
                        chunkInserted += 1
                    }
                    guard chunkInserted > 0 else { return }
                    #if DEBUG
                    pingChunkSaveCountForTesting += 1
                    if failingPingChunkSaveForTesting == pingChunkSaveCountForTesting {
                        failingPingChunkSaveForTesting = nil
                        context.rollback()
                        throw CocoaError(.fileWriteUnknown)
                    }
                    #endif
                    try context.save()
                    inserted += chunkInserted
                }
            }
        } catch {
            logger.error("JSON import ping chunk failed: \(error.localizedDescription)")
            return (inserted, true)
        }
        return (inserted, false)
    }
}
