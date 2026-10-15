//
//  TripDataImporter+StayPersistence.swift
//  TravelLog
//

import Foundation
import SwiftData
import CoreLocation
import os.log

extension TripDataImporter {

    /// Synthetic pings carry a sentinel accuracy well above real GPS values
    /// so any future diagnostics can tell them apart from recorded fixes.
    private static let syntheticAccuracy: Double = 999

    func pendingGeocodes() -> [PendingGeocode] { pendingGeocodeSnapshots }

    #if DEBUG
    func applyGeocodeHealForTesting(
        stayID: UUID,
        result: GeocodeResolver.Result
    ) -> Int {
        applyGeocodeHeals([(stayID: stayID, result: result)])
    }
    #endif

    /// Phase 2 of a restore: heal the offline place layers for the
    /// just-inserted stays WITHOUT any gate unit spanning the geocode
    /// awaits. Gate discipline lives INSIDE this method (the
    /// `TransitInferer.recorroborateUnknownLegs` shape): resolution runs
    /// ungated against the offline resolver, and writes land through
    /// short per-chunk gate units that re-fetch each stay by id and
    /// re-validate its fields are still nil — so a queued background SLC
    /// wake-ping save can interleave between chunks. Callers must invoke
    /// this OUTSIDE any PipelineGate unit (the gate is non-reentrant).
    /// Returns the number of stays healed.
    @discardableResult
    func healPendingGeocodes(
        _ pending: [PendingGeocode], gate: PipelineGate = .shared
    ) async -> Int {
        guard !pending.isEmpty else { return 0 }

        // Ungated resolution phase. Coalesce rules re-checked at apply
        // time; a resolver miss (remote area) leaves the nils — idempotent.
        var resolutions: [(stayID: UUID, result: GeocodeResolver.Result)] = []
        for snapshot in pending {
            if let r = await GeocodeResolver.shared.resolve(
                latitude: snapshot.latitude, longitude: snapshot.longitude
            ) {
                resolutions.append((snapshot.stayID, r))
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

    /// Gated apply for one heal chunk: re-fetch by id, re-check the
    /// import-time coalesce conditions still hold (the stay may have been
    /// deleted or geocoded by another lane while no gate was held), write,
    /// refresh affected trip summaries, save once.
    private func applyGeocodeHeals(_ chunk: [(stayID: UUID, result: GeocodeResolver.Result)]) -> Int {
        var healed = 0
        let ids = chunk.map(\.stayID)
        let predicate = #Predicate<Stay> { ids.contains($0.id) }
        let fetched = (try? modelContext.fetch(FetchDescriptor<Stay>(predicate: predicate))) ?? []
        let staysByID = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var titleSnapshots:
            [ObjectIdentifier: TripTitleStore.ParentSemanticSnapshot] = [:]
        for (stayID, r) in chunk {
            guard let stay = staysByID[stayID],
                  stay.administrativeArea == nil, stay.metroName == nil,
                  stay.islandName == nil else {
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
        // Refresh every healed parent, even with unchanged title inputs;
        // imports may keep a summary built without the home-place filter.
        for snapshot in titleSnapshots.values {
            let trip = snapshot.trip
            guard !trip.isDeleted,
                  snapshot.semantic == TripTitleStore.semanticSnapshot(for: trip) else {
                continue
            }
            trip.recomputeSummary()
        }
        _ = try? TripTitleStore.invalidateChangedParentTitles(
            from: Array(titleSnapshots.values), in: modelContext)
        if healed > 0 { save() }
        return healed
    }

    /// Builds + inserts one imported stay (synthetic pings, field copies,
    /// dayKey backfill, offline geocode heal) WITHOUT trip linking — shared
    /// by the per-trip loop and the v5 unassigned-stays loop so the two
    /// paths cannot drift.
    func insertImportedStay(
        _ importedStay: ImportedStay, h3Index: String, retainedRevisions: [UUID: Int]
    ) -> Stay {
        let pingIDs = insertSyntheticPings(for: importedStay, h3Index: h3Index)
        let stay = Stay(
            startTime: importedStay.startTime,
            endTime: importedStay.endTime,
            centroidLatitude: importedStay.latitude,
            centroidLongitude: importedStay.longitude,
            h3IndexRes6: h3Index,
            pingCount: max(importedStay.pingCount ?? 0, pingIDs.count),
            distanceFromHomeKm: importedStay.distanceFromHomeKm ?? 0,
            pingIDs: pingIDs,
            source: Self.source(from: importedStay.sourceRaw)
        )
        stay.id = importedStay.id
        if let raw = importedStay.categoryRaw, StayCategory(rawValue: raw) != nil {
            stay.categoryRaw = raw
        }
        // v12 provenance describes a home stamp; any other stay takes none.
        // v13: its revision rides with it, clamped to the declaration this
        // import keeps (`retainedTemporaryHomeRevisions`).
        if stay.category == .home, let id = importedStay.temporaryHomeID {
            let revision = importedStay.temporaryHomeRevision.map { revision in
                retainedRevisions[id].map { min(revision, $0) } ?? revision
            }
            stay.setTemporaryHomeProvenance(id, revision: revision)
        }
        stay.userOverridden = importedStay.userOverridden ?? false
        // Derived, so stamped from the restored centroid with the bundled
        // dataset, as live clustering and import attachment do: a backup
        // made before an airport joined the dataset carries a stale false,
        // and the one-shot airport backfill is latched on a used device.
        // The file's flag stands only when the dataset did not load.
        stay.isAirport = AirportDetector.shared.airportCount > 0
            ? AirportDetector.shared.isNearAirport(CLLocationCoordinate2D(
                latitude: importedStay.latitude, longitude: importedStay.longitude))
            : importedStay.isAirport ?? false
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
        // v10 carries the zone the exporting device stamped; older files
        // fall back to the longitude rule (`StayTimeZone`), which for a
        // restored backup is the same rule the original import used.
        stay.timeZoneIdentifier = importedStay.timeZoneIdentifier
            .flatMap { TimeZone(identifier: $0) != nil ? $0 : nil }
            ?? StayTimeZone.approximateZone(
                forLongitude: importedStay.longitude,
                isoCountryCode: importedStay.isoCountryCode,
                at: importedStay.startTime).identifier
        // v1/v2 files predate dayKey — recompute it from startTime
        // (the same UTC start-of-day rule WeatherEnricher stamps) so
        // the (h3IndexRes6, dayKey) weather-cache predicate keeps
        // matching restored stays.
        stay.dayKey = importedStay.dayKey ?? WeatherEnricher.computeDayKey(for: importedStay.startTime)
        // v1/v2 files predate the offline-geocoder layers entirely
        // (administrativeArea / metroName / islandName), and the
        // one-shot geocoder backfills are already LATCHED on any
        // previously-used device — restored stays would keep nil
        // place layers forever ("California" search misses them,
        // Places loses metro/island grouping). The heal itself runs
        // AFTER the import's gate unit ends (per-stay resolver awaits
        // inside one held unit would starve queued SLC wake-ping
        // saves); here we only snapshot the candidates.
        if stay.administrativeArea == nil, stay.metroName == nil,
           stay.islandName == nil {
            pendingGeocodeSnapshots.append(PendingGeocode(
                stayID: stay.id,
                latitude: stay.centroidLatitude,
                longitude: stay.centroidLongitude
            ))
        }
        modelContext.insert(stay)
        return stay
    }

    /// Two synthetic pings per stay (one at start, one at end — a single
    /// ping when the stay is instantaneous). `isProcessed = true`: the stay
    /// already exists, so `StayClusterer` must never re-cluster these into
    /// a duplicate. Always `.jsonImport` (see type doc).
    private func insertSyntheticPings(for stay: ImportedStay, h3Index: String) -> [UUID] {
        var timestamps = [stay.startTime]
        if stay.endTime > stay.startTime {
            timestamps.append(stay.endTime)
        }
        return timestamps.map { timestamp in
            let ping = LocationPing(
                timestamp: timestamp,
                latitude: stay.latitude,
                longitude: stay.longitude,
                horizontalAccuracy: Self.syntheticAccuracy,
                h3IndexRes6: h3Index,
                source: .jsonImport
            )
            ping.isProcessed = true
            ping.locality = stay.locality
            ping.subLocality = stay.subLocality
            ping.administrativeArea = stay.administrativeArea
            ping.country = stay.country
            ping.isoCountryCode = stay.isoCountryCode
            ping.isGeocoded = (stay.locality != nil || stay.country != nil)
            modelContext.insert(ping)
            return ping.id
        }
    }

    /// Conservative HexVisit upsert: bounds-extension only on existing rows
    /// (no visitCount inflation — the export has no re-entry data), fresh
    /// rows at visitCount 1. Per-call cache avoids refetching repeated
    /// hexes; safe because the whole import runs in one PipelineGate unit.
    /// Throws on a failed lookup: treating it as absence would insert a
    /// duplicate row for a hex the store already holds.
    func upsertHexVisit(h3Index: String, for stay: ImportedStay, cache: inout [String: HexVisit]) throws {
        let hexVisit: HexVisit?
        if let cached = cache[h3Index] {
            hexVisit = cached
        } else {
            #if DEBUG
            hexVisitFetchCallCountForTesting += 1
            if failingHexVisitFetchCallForTesting == hexVisitFetchCallCountForTesting {
                failingHexVisitFetchCallForTesting = nil
                throw CocoaError(.fileReadUnknown)
            }
            #endif
            let predicate = #Predicate<HexVisit> { $0.h3Index == h3Index }
            hexVisit = try modelContext.fetch(FetchDescriptor<HexVisit>(predicate: predicate)).first
        }

        if let hexVisit {
            if stay.startTime < hexVisit.firstVisited { hexVisit.firstVisited = stay.startTime }
            if stay.endTime > hexVisit.lastVisited { hexVisit.lastVisited = stay.endTime }
            if hexVisit.locality == nil { hexVisit.locality = stay.locality }
            if hexVisit.country == nil {
                hexVisit.country = stay.country
                hexVisit.isoCountryCode = stay.isoCountryCode
            }
            cache[h3Index] = hexVisit
        } else {
            let center = H3Service.centerCoordinate(for: h3Index)
            let newVisit = HexVisit(
                h3Index: h3Index,
                firstVisited: stay.startTime,
                centerLatitude: center?.latitude ?? stay.latitude,
                centerLongitude: center?.longitude ?? stay.longitude
            )
            newVisit.lastVisited = stay.endTime
            newVisit.locality = stay.locality
            newVisit.country = stay.country
            newVisit.isoCountryCode = stay.isoCountryCode
            modelContext.insert(newVisit)
            cache[h3Index] = newVisit
        }
    }
}
