//
//  PhotoImportOrphanReadoptionTests.swift
//  TravelLogTests
//
//  Covers the orphan import-ping re-adoption sweep: a cross-device rewrite
//  of a stay's ping list can win a whole-field CloudKit LWW
//  merge over an importing device's concurrent pingIDsString append,
//  stranding freshly-attached pings as isProcessed==true rows referenced by
//  no stay — which nothing re-clustered. The sweep flips AGED orphans back
//  to isProcessed=false (StayClusterer re-folds them); the first-observed
//  grace period keeps transient CloudKit arrival order from triggering
//  spurious re-clusters.
//
//  Injected UserDefaults suite + clock — the shared-standard-defaults race
//  the FM-cache tests hit is designed out.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct PhotoImportOrphanReadoptionTests {

    private static let athens = (lat: 37.9838, lon: 23.7275)
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeDefaults() throws -> UserDefaults {
        let suite = "orphan-readoption-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @discardableResult
    private func ping(
        in ctx: ModelContext, id: UUID = UUID(), source: DataSource,
        processed: Bool = true
    ) -> LocationPing {
        let ping = LocationPing(
            timestamp: Self.base, latitude: Self.athens.lat, longitude: Self.athens.lon,
            horizontalAccuracy: 30, h3IndexRes6: "hex", source: source
        )
        ping.id = id
        ping.isProcessed = processed
        ctx.insert(ping)
        return ping
    }

    @Test("an aged orphan is re-adopted; referenced and young pings are untouched")
    func agedOrphanIsReadopted() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let defaults = try makeDefaults()

        let referencedID = UUID()
        let orphanID = UUID()
        ping(in: ctx, id: referencedID, source: .timelineImport)
        ping(in: ctx, id: orphanID, source: .timelineImport)
        let stay = Stay(
            startTime: Self.base, endTime: Self.base.addingTimeInterval(3600),
            centroidLatitude: Self.athens.lat, centroidLongitude: Self.athens.lon,
            h3IndexRes6: "hex", pingCount: 1, distanceFromHomeKm: 0,
            pingIDs: [referencedID]
        )
        ctx.insert(stay)
        try ctx.save()

        // First sighting: nothing flips, the orphan's age starts counting.
        await PhotoImportPingDeduplicator.readoptOrphanImportPings(
            modelContainer: container, now: Self.base, defaults: defaults,
            importActivityProbe: { false }
        )
        var fresh = ModelContext(container)
        var pings = try fresh.fetch(FetchDescriptor<LocationPing>())
        #expect(pings.allSatisfy { $0.isProcessed })

        // Past the grace period: the orphan re-enters the cluster pipeline;
        // the referenced ping stays processed.
        await PhotoImportPingDeduplicator.readoptOrphanImportPings(
            modelContainer: container,
            now: Self.base.addingTimeInterval(PhotoImportPingDeduplicator.orphanPingGracePeriod),
            defaults: defaults,
            importActivityProbe: { false }
        )
        fresh = ModelContext(container)
        pings = try fresh.fetch(FetchDescriptor<LocationPing>())
        #expect(pings.first { $0.id == orphanID }?.isProcessed == false)
        #expect(pings.first { $0.id == referencedID }?.isProcessed == true)
        // The re-adopted entry left the first-observed map.
        let observed = defaults.dictionary(forKey: PhotoImportPingDeduplicator.orphanPingFirstObservedKey) ?? [:]
        #expect(observed.isEmpty)
    }

    @Test("a transiently-orphaned ping that gets re-referenced is forgiven, and an empty stay table is treated as mid-sync")
    func transientOrphanAndMidSyncGuards() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let defaults = try makeDefaults()

        let lateID = UUID()
        ping(in: ctx, id: lateID, source: .gpxImport)
        try ctx.save()

        // Zero stays + import pings present = hydration in flight: the sweep
        // must not even start aging (a fresh-restore device would otherwise
        // age EVERY ping while its stays sync in).
        await PhotoImportPingDeduplicator.readoptOrphanImportPings(
            modelContainer: container, now: Self.base, defaults: defaults,
            importActivityProbe: { false }
        )
        #expect((defaults.dictionary(forKey: PhotoImportPingDeduplicator.orphanPingFirstObservedKey) ?? [:]).isEmpty)

        // A stay exists but doesn't reference the ping yet → aging starts.
        let stay = Stay(
            startTime: Self.base, endTime: Self.base.addingTimeInterval(3600),
            centroidLatitude: Self.athens.lat, centroidLongitude: Self.athens.lon,
            h3IndexRes6: "hex", pingCount: 1, distanceFromHomeKm: 0,
            pingIDs: [UUID()]
        )
        ctx.insert(stay)
        try ctx.save()
        await PhotoImportPingDeduplicator.readoptOrphanImportPings(
            modelContainer: container, now: Self.base, defaults: defaults,
            importActivityProbe: { false }
        )
        #expect(!(defaults.dictionary(forKey: PhotoImportPingDeduplicator.orphanPingFirstObservedKey) ?? [:]).isEmpty)

        // The stay's pingIDsString write arrives (transient order healed):
        // the next sweep forgives the ping — no flip, map entry dropped.
        stay.pingIDs = stay.pingIDs + [lateID]
        try ctx.save()
        await PhotoImportPingDeduplicator.readoptOrphanImportPings(
            modelContainer: container,
            now: Self.base.addingTimeInterval(PhotoImportPingDeduplicator.orphanPingGracePeriod * 2),
            defaults: defaults,
            importActivityProbe: { false }
        )
        let fresh = ModelContext(container)
        let pings = try fresh.fetch(FetchDescriptor<LocationPing>())
        #expect(pings.allSatisfy { $0.isProcessed })
        #expect((defaults.dictionary(forKey: PhotoImportPingDeduplicator.orphanPingFirstObservedKey) ?? [:]).isEmpty)
    }
}
