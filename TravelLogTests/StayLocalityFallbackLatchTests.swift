//
//  StayLocalityFallbackLatchTests.swift
//  TravelLogTests
//
//  The one-shot MapKit-fallback locality backfill latches only after a pass
//  that saved every candidate. A failed candidate read must not look like an
//  empty candidate list, or the pass would latch and never retry. A marker
//  older builds latched under weaker accounting must not count as complete.
//  Delete All Data stops both stay MapKit passes before their next lookup,
//  and a lookup a cache clear revokes is never latched over.
//

import Foundation
import os
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Stay locality fallback latch", .serialized)
struct StayLocalityFallbackLatchTests {

    @Test("an empty candidate set reports a saved pass")
    func emptyStoreIsSaved() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let result = await AppDelegate.backfillStayLocalityFallback(modelContainer: container)
        #expect(result.saved)
        #expect(result.attempted == 0)
    }

    @Test("a failed candidate read reports an unsaved pass so the key stays unset")
    func readFailureIsNotSaved() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = container.mainContext
        let start = Date(timeIntervalSinceReferenceDate: 695 * 86_400)
        let stay = Stay(
            startTime: start, endTime: start.addingTimeInterval(3600),
            centroidLatitude: 37.98, centroidLongitude: 23.72,
            h3IndexRes6: "hexA", pingCount: 1, distanceFromHomeKm: 10, pingIDs: [])
        stay.country = "Greece"
        ctx.insert(stay)
        try ctx.save()

        AppDelegate.failStayLocalityCandidateFetchForTesting = true
        defer { AppDelegate.failStayLocalityCandidateFetchForTesting = false }
        let result = await AppDelegate.backfillStayLocalityFallback(modelContainer: container)
        #expect(!result.saved)
        #expect(result.attempted == 0)
    }

    @Test("a failed apply read rolls back the staged stay and reports an unsaved chunk")
    func applyReadFailureIsNotSaved() async throws {
        // This coordinate resolves from the bundled offline data, so the
        // fallback worker reaches apply without a MapKit request or a wait.
        let latitude = 37.8677
        let longitude = 24.7432
        let resolved = try #require(await GeocodeResolver.shared.resolve(
            latitude: latitude, longitude: longitude))
        _ = try #require(resolved.localityForStorage)
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = container.mainContext
        let start = Date(timeIntervalSinceReferenceDate: 695 * 86_400)
        // Two candidates in one chunk: the first is staged before the
        // second lookup throws, so the rollback check has work to undo.
        for (index, hex) in ["hexA", "hexB"].enumerated() {
            let stayStart = start.addingTimeInterval(Double(index) * 7200)
            let stay = Stay(
                startTime: stayStart, endTime: stayStart.addingTimeInterval(3600),
                centroidLatitude: latitude, centroidLongitude: longitude,
                h3IndexRes6: hex, pingCount: 1, distanceFromHomeKm: 10, pingIDs: [])
            stay.country = "Greece"
            ctx.insert(stay)
        }
        try ctx.save()

        AppDelegate.failStayLocalityApplyFetchForTesting = true
        AppDelegate.failStayLocalityApplyFetchCallForTesting = 2
        AppDelegate.stayLocalityApplyHasChangesAfterRollbackForTesting = nil
        defer {
            AppDelegate.failStayLocalityApplyFetchForTesting = false
            AppDelegate.failStayLocalityApplyFetchCallForTesting = 1
            AppDelegate.stayLocalityApplyHasChangesAfterRollbackForTesting = nil
        }
        let result = await AppDelegate.backfillStayLocalityFallback(modelContainer: container)
        #expect(!result.saved)
        #expect(result.attempted == 2)
        #expect(result.filled == 0)
        #expect(AppDelegate.stayLocalityApplyHasChangesAfterRollbackForTesting == false)
        let stays = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        #expect(stays.count == 2)
        #expect(stays.allSatisfy { $0.locality == nil && $0.country == "Greece" })
    }

    @Test("a marker latched by an offline pass in older builds reruns until Apple answers",
          .timeLimit(.minutes(1)))
    func legacyMarkerFromOfflinePassReruns() async throws {
        let suite = "stay-locality-fallback-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        // Older builds latched this marker after a pass whose MapKit lookups all failed offline.
        defaults.set(true, forKey: "stayLocalityFallbackBackfillCompleted_v1")

        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let start = Date(timeIntervalSinceReferenceDate: 695 * 86_400)
        let unnamed = Stay(
            startTime: start, endTime: start.addingTimeInterval(3600),
            centroidLatitude: 37.9838, centroidLongitude: 23.7275,
            h3IndexRes6: "hexA", pingCount: 1, distanceFromHomeKm: 10, pingIDs: [])
        unnamed.country = "Greece"
        unnamed.administrativeArea = "Attiki"
        ctx.insert(unnamed)
        let named = Stay(
            startTime: start.addingTimeInterval(7200), endTime: start.addingTimeInterval(10_800),
            centroidLatitude: 37.9838, centroidLongitude: 23.7275,
            h3IndexRes6: "hexA", pingCount: 1, distanceFromHomeKm: 10, pingIDs: [])
        named.country = "Greece"
        named.locality = "Kept Town"
        ctx.insert(named)
        try ctx.save()
        let unnamedID = unnamed.id
        let namedID = named.id
        func stay(_ id: UUID) throws -> Stay? {
            try ModelContext(container).fetch(
                FetchDescriptor<Stay>(predicate: #Predicate { $0.id == id })).first
        }

        await MapKitLocalityCache.shared.clearCache()
        _ = await MapKitLocalityCache.shared.consumeDropCount()
        let offline = GeocodeResolver.Result(
            country: "Greece", isoCountryCode: "GR", administrativeArea: "Attiki",
            metroName: nil, localityName: nil, subLocalityName: nil, islandName: nil)

        // The first launch after the upgrade is still offline: the lookup counts as
        // unresolved, so the current marker stays unset for a later launch.
        await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in offline }) {
            await MapKitLocalityCache.TestHook.$reverseGeocode.withValue({ _ in
                throw URLError(.notConnectedToInternet)
            }) {
                await AppDelegate.runStayLocalityFallbackBackfillIfNeeded(
                    modelContainer: container, defaults: defaults)
            }
        }
        #expect(!defaults.bool(forKey: AppDelegate.stayLocalityFallbackBackfillCompletedKey))
        #expect(try stay(unnamedID)?.locality == nil)

        // A later launch reaches Apple and fills only the missing values.
        await MapKitLocalityCache.TestHook.$enrich.withValue({ _, _, _, _ in
            GeocodeResolver.Result(
                country: "Greece", isoCountryCode: "GR", administrativeArea: "Other Region",
                metroName: nil, localityName: "Stub MapKit Town", subLocalityName: nil, islandName: nil)
        }) {
            await AppDelegate.runStayLocalityFallbackBackfillIfNeeded(
                modelContainer: container, defaults: defaults)
        }
        let filled = try #require(try stay(unnamedID))
        #expect(filled.locality == "Stub MapKit Town")
        #expect(filled.administrativeArea == "Attiki")
        #expect(filled.isoCountryCode == "GR")
        #expect(try stay(namedID)?.locality == "Kept Town")

        await MapKitLocalityCache.shared.clearCache()
        _ = await MapKitLocalityCache.shared.consumeDropCount()
    }
    nonisolated static func named(_ locality: String?) -> GeocodeResolver.Result {
        GeocodeResolver.Result(
            country: "Greece", isoCountryCode: "GR", administrativeArea: "Attiki",
            metroName: nil, localityName: locality, subLocalityName: nil, islandName: nil)
    }

    @Test("a centroid that moves to another cell during the lookup defers apply and the latch",
          .timeLimit(.minutes(1)), arguments: [true, false])
    func movedCentroidDefersLatch(lookupNamed: Bool) async throws {
        let suite = "stay-locality-fallback-drift-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let origin = (latitude: 37.9838, longitude: 23.7275)
        let moved = (latitude: 37.9281, longitude: 23.7631)
        #expect(MapKitLocalityCache.cellKey(latitude: origin.latitude, longitude: origin.longitude)
            != MapKitLocalityCache.cellKey(latitude: moved.latitude, longitude: moved.longitude))

        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let start = Date(timeIntervalSinceReferenceDate: 695 * 86_400)
        let stay = Stay(
            startTime: start, endTime: start.addingTimeInterval(3600),
            centroidLatitude: origin.latitude, centroidLongitude: origin.longitude,
            h3IndexRes6: "hexA", pingCount: 1, distanceFromHomeKm: 10, pingIDs: [])
        stay.country = "Greece"
        ctx.insert(stay)
        try ctx.save()
        func current() throws -> Stay? {
            try ModelContext(container).fetch(FetchDescriptor<Stay>()).first
        }

        await MapKitLocalityCache.shared.clearCache()
        _ = await MapKitLocalityCache.shared.consumeDropCount()
        let offline = Self.named(nil)
        // Live clustering extends the stay into the next cell while the lookup is out.
        await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in offline }) {
            await MapKitLocalityCache.TestHook.$enrich.withValue({ offline, _, _, _ in
                await MainActor.run {
                    let context = ModelContext(container)
                    let row = try! context.fetch(FetchDescriptor<Stay>()).first!
                    row.centroidLatitude = moved.latitude
                    row.centroidLongitude = moved.longitude
                    try! context.save()
                }
                return lookupNamed ? Self.named("Old Cell Town") : offline
            }) {
                await AppDelegate.runStayLocalityFallbackBackfillIfNeeded(
                    modelContainer: container, defaults: defaults)
            }
        }
        #expect(!defaults.bool(forKey: AppDelegate.stayLocalityFallbackBackfillCompletedKey))
        #expect(try current()?.locality == nil)

        // The next launch snapshots the moved centroid and applies its own answer.
        await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in offline }) {
            await MapKitLocalityCache.TestHook.$enrich.withValue({ _, _, _, _ in
                Self.named("New Cell Town")
            }) {
                await AppDelegate.runStayLocalityFallbackBackfillIfNeeded(
                    modelContainer: container, defaults: defaults)
            }
        }
        #expect(defaults.bool(forKey: AppDelegate.stayLocalityFallbackBackfillCompletedKey))
        #expect(try current()?.locality == "New Cell Town")

        await MapKitLocalityCache.shared.clearCache()
        _ = await MapKitLocalityCache.shared.consumeDropCount()
    }

    @Test("Delete All Data during a lookup stops the pass before any pre-wipe centroid is looked up again",
          .timeLimit(.minutes(1)), arguments: [false, true])
    func wipeDuringLookupStopsThePass(offlineGeocoderPass: Bool) async throws {
        let suite = "stay-locality-fallback-wipe-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let start = Date(timeIntervalSinceReferenceDate: 695 * 86_400)
        for index in 0..<3 {
            let stayStart = start.addingTimeInterval(Double(index) * 7200)
            let stay = Stay(
                startTime: stayStart, endTime: stayStart.addingTimeInterval(3600),
                centroidLatitude: 37.9838 + Double(index) * 0.02, centroidLongitude: 23.7275,
                h3IndexRes6: "hexA", pingCount: 1, distanceFromHomeKm: 10, pingIDs: [])
            stay.country = "Greece"
            ctx.insert(stay)
        }
        try ctx.save()

        let lookups = OSAllocatedUnfairLock(initialState: 0)
        let offline = Self.named(nil)
        let saved = await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in offline }) {
            await MapKitLocalityCache.TestHook.$enrich.withValue({ _, _, _, _ in
                // Delete All Data commits while the first lookup is out.
                if lookups.withLock({ $0 += 1; return $0 }) == 1 {
                    await PipelineGate.shared.run(touching: []) {
                        await MainActor.run {
                            _ = DataWipe.execute(
                                container: container, defaults: UserDefaults(suiteName: suite)!,
                                clearDissolvedQueue: {}, obsoleteStoreFamily: { _ in nil })
                        }
                    }
                }
                return Self.named("Old Town")
            }) {
                offlineGeocoderPass
                    ? await AppDelegate.backfillOfflineGeocoder(
                        modelContainer: container, defaults: defaults).saved
                    : await AppDelegate.backfillStayLocalityFallback(
                        modelContainer: container, defaults: defaults).saved
            }
        }
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Stay>()) == 0)
        #expect(lookups.withLock { $0 } == 1, "no centroid snapshotted before the wipe is looked up after it")
        #expect(!saved, "the key stays unset for whatever the store holds next")
    }

    @Test("a lookup a cache clear revokes after a failed wipe leaves the pass unlatched",
          .timeLimit(.minutes(1)))
    func revokedLookupLeavesThePassUnlatched() async throws {
        let suite = "stay-locality-fallback-revoked-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let start = Date(timeIntervalSinceReferenceDate: 695 * 86_400)
        let stay = Stay(
            startTime: start, endTime: start.addingTimeInterval(3600),
            centroidLatitude: 37.9838, centroidLongitude: 23.7275,
            h3IndexRes6: "hexA", pingCount: 1, distanceFromHomeKm: 10, pingIDs: [])
        stay.country = "Greece"
        ctx.insert(stay)
        try ctx.save()

        await MapKitLocalityCache.shared.clearCache()
        _ = await MapKitLocalityCache.shared.consumeDropCount()
        let offline = Self.named(nil)
        // A rolled-back wipe leaves the floor alone, but Settings still clears the cache while the lookup is out.
        await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in offline }) {
            await MapKitLocalityCache.TestHook.$reverseGeocode.withValue({ _ in
                await MapKitLocalityCache.shared.clearCache()
                return []
            }) {
                await AppDelegate.runStayLocalityFallbackBackfillIfNeeded(
                    modelContainer: container, defaults: defaults)
            }
        }
        #expect(!defaults.bool(forKey: AppDelegate.stayLocalityFallbackBackfillCompletedKey),
                "the revoked lookup is retried next launch")
        #expect(try ModelContext(container).fetch(FetchDescriptor<Stay>()).first?.locality == nil)

        await MapKitLocalityCache.shared.clearCache()
        _ = await MapKitLocalityCache.shared.consumeDropCount()
    }

    @Test("physical twins sharing a UUID each take the name for their own centroid")
    func twinsTakeTheirOwnNames() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let start = Date(timeIntervalSinceReferenceDate: 695 * 86_400)
        let shared = UUID()
        for (latitude, longitude) in [(37.9838, 23.7275), (37.9281, 23.7631)] {
            let stay = Stay(
                startTime: start, endTime: start.addingTimeInterval(3600),
                centroidLatitude: latitude, centroidLongitude: longitude,
                h3IndexRes6: "hexA", pingCount: 1, distanceFromHomeKm: 10, pingIDs: [])
            stay.id = shared
            stay.country = "Greece"
            ctx.insert(stay)
        }
        try ctx.save()

        let offline = Self.named(nil)
        let result = await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in offline }) {
            await MapKitLocalityCache.TestHook.$enrich.withValue({ _, latitude, _, _ in
                Self.named(latitude < 37.95 ? "South Town" : "North Town")
            }) {
                await AppDelegate.backfillStayLocalityFallback(modelContainer: container)
            }
        }
        #expect(result.saved)
        #expect(result.filled == 2)
        #expect(result.deferred == 0)
        let stays = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        #expect(stays.count == 2)
        for stay in stays {
            #expect(stay.locality == (stay.centroidLatitude < 37.95 ? "South Town" : "North Town"))
        }
    }
}
