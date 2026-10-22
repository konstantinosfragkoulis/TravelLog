//
//  GeocoderBackfillCleanPassTests.swift
//  TravelLogTests
//
//  The offline-geocoder backfill runs once on every device each time its
//  completion key moves. A row whose resolved fields already hold what the
//  resolver gives must stay clean: a same-value write is still a SwiftData
//  change, so rewriting it would save and export the whole store to CloudKit
//  again. Every row is re-resolved, whichever earlier passes a device latched,
//  so a wrong name without a bracketed qualifier is repaired too.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
@Suite("Geocoder backfill clean pass", .serialized)
struct GeocoderBackfillCleanPassTests {

    private static let base = Date(timeIntervalSinceReferenceDate: 722 * 86_400)
    // On land: the resolver answers nothing out at sea.
    private let place = (lat: 44.3, lon: 11.9)

    private func seedStore(_ container: ModelContainer) throws {
        let ctx = ModelContext(container)
        for i in 0..<3 {
            ctx.insert(LocationPing(
                timestamp: Self.base.addingTimeInterval(Double(i) * 600),
                latitude: place.lat, longitude: place.lon,
                horizontalAccuracy: 30, h3IndexRes6: "clean-pass-cell", source: .liveSLC))
        }
        let trip = Trip(startDate: Self.base)
        ctx.insert(trip)
        let stay = Stay(
            startTime: Self.base, endTime: Self.base.addingTimeInterval(3_600),
            centroidLatitude: place.lat, centroidLongitude: place.lon,
            h3IndexRes6: "clean-pass-cell", pingCount: 3,
            distanceFromHomeKm: 40, pingIDs: [])
        stay.category = .destination
        stay.trip = trip
        stay.orderInTrip = 0
        ctx.insert(stay)
        ctx.insert(HexVisit(
            h3Index: "clean-pass-cell", firstVisited: Self.base,
            centerLatitude: place.lat, centerLongitude: place.lon))
        try ctx.save()
    }

    @Test("a pass over rows that already hold the resolver's names changes and saves nothing",
          .timeLimit(.minutes(1)))
    func unchangedRowsStayClean() async throws {
        _ = try #require(await GeocodeResolver.shared.resolve(latitude: place.lat, longitude: place.lon),
                         "bundled geocoder unavailable in this run")
        let container = try TestSupport.makeInMemoryContainer()
        try seedStore(container)

        // The first pass fills every layer, so the store holds what the resolver gives.
        let first = await AppDelegate.backfillOfflineGeocoder(
            modelContainer: container, gate: PipelineGate(forTesting: ()))
        #expect(first.saved)
        #expect(first.updatedPings == 3 && first.updatedStays == 1 && first.updatedHexVisits == 1)
        let before = try #require(AppDelegate.newestHistoryToken(in: ModelContext(container)))

        // The rerun a moved completion key starts finds nothing to change.
        let second = await AppDelegate.backfillOfflineGeocoder(
            modelContainer: container, gate: PipelineGate(forTesting: ()))

        #expect(second.saved)
        #expect(second.updatedPings == 0)
        #expect(second.updatedStays == 0)
        #expect(second.updatedHexVisits == 0)
        #expect(second.recomputedTrips == 0)
        #expect(AppDelegate.newestHistoryToken(in: ModelContext(container)) == before,
                "an unchanged row was saved again, which would export it to CloudKit")
    }

    /// A device whose earlier passes latched: v11 over the whole store, v12
    /// over bracketed names only.
    private static func defaultsLatchedThroughV12() throws -> (UserDefaults, String) {
        let suite = "geocoder-clean-pass-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "offlineGeocoderBackfillCompleted_v11")
        defaults.set(true, forKey: "offlineGeocoderBackfillCompleted_v12")
        return (defaults, suite)
    }

    @Test("after the v11 and v12 passes latched, the pass repairs a wrong unbracketed row and leaves clean rows unwritten",
          .timeLimit(.minutes(1)))
    func latchedDeviceRepairsUnbracketedWrongRows() async throws {
        let resolved = try #require(
            await GeocodeResolver.shared.resolve(latitude: place.lat, longitude: place.lon),
            "bundled geocoder unavailable in this run")
        try #require(resolved.bestLocalityName != nil && resolved.isoCountryCode != nil)
        let (defaults, suite) = try Self.defaultsLatchedThroughV12()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        #expect(!defaults.bool(forKey: AppDelegate.offlineGeocoderBackfillCompletedKey))

        // Earlier passes left every row as the resolver gives it now ...
        let container = try TestSupport.makeInMemoryContainer()
        try seedStore(container)
        #expect(await AppDelegate.backfillOfflineGeocoder(
            modelContainer: container, gate: PipelineGate(forTesting: ())).saved)
        // ... except rows a cell centre named across a border: a wrong name
        // and country with no bracketed qualifier.
        let ctx = ModelContext(container)
        let pings = try ctx.fetch(FetchDescriptor<LocationPing>(sortBy: [SortDescriptor(\.timestamp)]))
        try #require(pings.count == 3)
        let stay = try #require(try ctx.fetch(FetchDescriptor<Stay>()).first)
        let hex = try #require(try ctx.fetch(FetchDescriptor<HexVisit>()).first)
        pings[0].locality = "Wrongton"
        pings[0].country = "Otherland"
        pings[0].isoCountryCode = "ZZ"
        stay.locality = "Wrongton"
        stay.country = "Otherland"
        stay.isoCountryCode = "ZZ"
        hex.locality = "Wrongton"
        hex.country = "Otherland"
        hex.isoCountryCode = "ZZ"
        try ctx.save()
        let wrong: Set = [pings[0].persistentModelID, stay.persistentModelID, hex.persistentModelID]
        let clean: Set = [pings[1].persistentModelID, pings[2].persistentModelID]
        let before = try #require(AppDelegate.newestHistoryToken(in: ModelContext(container)))

        await AppDelegate.runOfflineGeocoderBackfillIfNeeded(
            modelContainer: container, defaults: defaults)

        #expect(defaults.bool(forKey: AppDelegate.offlineGeocoderBackfillCompletedKey))
        let fresh = ModelContext(container)
        for ping in try fresh.fetch(FetchDescriptor<LocationPing>()) {
            #expect(ping.locality == resolved.localityForStorage)
            #expect(ping.isoCountryCode == resolved.isoCountryCode)
        }
        let repairedStay = try #require(try fresh.fetch(FetchDescriptor<Stay>()).first)
        #expect(repairedStay.locality == resolved.localityForStorage)
        #expect(repairedStay.isoCountryCode == resolved.isoCountryCode)
        let repairedHex = try #require(try fresh.fetch(FetchDescriptor<HexVisit>()).first)
        #expect(repairedHex.isoCountryCode == resolved.isoCountryCode)

        // Only the wrong rows were written.
        var written = Set<PersistentIdentifier>()
        for transaction in try fresh.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>())
        where transaction.token > before {
            for change in transaction.changes {
                if case .delete = change { continue }
                written.insert(change.changedPersistentIdentifier)
            }
        }
        #expect(wrong.isSubset(of: written))
        #expect(written.isDisjoint(with: clean), "a row already clean was saved again")
    }

    @Test("a pass Delete All Data stops stays owed, and its retry repairs the rows it never reached",
          .timeLimit(.minutes(2)))
    func stoppedPassStaysOwed() async throws {
        let resolved = try #require(
            await GeocodeResolver.shared.resolve(latitude: place.lat, longitude: place.lon),
            "bundled geocoder unavailable in this run")
        try #require(resolved.bestLocalityName != nil && resolved.isoCountryCode != nil)
        let (defaults, suite) = try Self.defaultsLatchedThroughV12()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        // One more stay than a page: the last one is read on the second page.
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let total = AppDelegate.geocoderBackfillStayPage + 1
        for i in 0..<total {
            let stay = Stay(
                startTime: Self.base.addingTimeInterval(Double(i) * 3_600),
                endTime: Self.base.addingTimeInterval(Double(i) * 3_600 + 1_800),
                centroidLatitude: place.lat, centroidLongitude: place.lon,
                h3IndexRes6: "clean-pass-cell", pingCount: 1,
                distanceFromHomeKm: 40, pingIDs: [])
            stay.category = .destination
            stay.locality = "Wrongton"
            stay.isoCountryCode = "ZZ"
            ctx.insert(stay)
        }
        try ctx.save()

        // A wipe's acceptance floor advances after the first apply chunk.
        let fired = CleanPassProbeCounter()
        AppDelegate.geocoderBackfillInterChunkProbe = { @Sendable in
            guard await fired.completions == 0 else { return }
            await fired.bump()
            UserDefaults(suiteName: suite)?.set(Date.now, forKey: PingRecorder.liveAcceptanceFloorKey)
        }
        await AppDelegate.runOfflineGeocoderBackfillIfNeeded(
            modelContainer: container, defaults: defaults)
        AppDelegate.geocoderBackfillInterChunkProbe = nil

        #expect(await fired.completions == 1)
        #expect(!defaults.bool(forKey: AppDelegate.offlineGeocoderBackfillCompletedKey),
                "a stopped pass must stay owed")
        let unreached = try #require(try ModelContext(container).fetch(
            FetchDescriptor<Stay>(sortBy: [SortDescriptor(\.startTime)])).last)
        #expect(unreached.isoCountryCode == "ZZ")

        // The next launch's retry finishes the pass and latches.
        await AppDelegate.runOfflineGeocoderBackfillIfNeeded(
            modelContainer: container, defaults: defaults)
        #expect(defaults.bool(forKey: AppDelegate.offlineGeocoderBackfillCompletedKey))
        let stays = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        #expect(stays.count == total)
        #expect(stays.allSatisfy {
            $0.isoCountryCode == resolved.isoCountryCode && $0.locality == resolved.localityForStorage
        })
    }
}

private actor CleanPassProbeCounter {
    private(set) var completions = 0
    func bump() { completions += 1 }
}
