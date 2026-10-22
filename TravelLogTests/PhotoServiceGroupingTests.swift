//
//  PhotoServiceGroupingTests.swift
//  TravelLogTests
//
//  Pins the pure geometric core of `PhotoService`'s photo grouping —
//  `PhotoService.nearestStayID`, the per-asset decision extracted out of
//  `groupAssetsByStay` when the fetch/grouping moved off the main actor.
//
//  `PHAsset`s cannot be synthesized in a unit test, so the seam takes the
//  asset's (optional) `CLLocation` + `creationDate` plus the same
//  pre-sorted `StayGroupContext` array that `groupAssetsByStay` builds.
//  These tests reproduce that pipeline (snapshots → sort by orderInTrip →
//  contexts) and assert the byte-for-byte semantics of the old inline loop:
//
//  1. GPS asset: geodesic-nearest in-window stay wins (strict `<`, so the
//     lowest-`orderInTrip` stay wins exact ties).
//  2. No-GPS asset: the FIRST in-window stay in `orderInTrip` order wins.
//  3. No in-window stay: fall back to the stay whose mid-time is closest
//     (over ALL stays).
//  4. Empty context array → nil.
//
//  `@MainActor` because the app target compiles with MainActor-by-default
//  isolation.
//

import Testing
import Foundation
import CoreLocation
import SwiftData
@testable import TravelLog

@MainActor
struct PhotoServiceGroupingTests {

    /// Reference epoch for deterministic dates.
    private static let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func snapshot(
        id: UUID,
        lat: Double,
        lon: Double,
        start: Date,
        durationHours: Double,
        order: Int
    ) -> StaySnapshot {
        StaySnapshot(
            id: id,
            latitude: lat,
            longitude: lon,
            startTime: start,
            endTime: start.addingTimeInterval(durationHours * 3600),
            orderInTrip: order,
            durationMinutes: Int(durationHours * 60),
            locality: nil,
            categoryRaw: StayCategory.destination.rawValue
        )
    }

    /// Mirror of `groupAssetsByStay`'s context prep: sort by `orderInTrip`,
    /// then map to contexts.
    private func contexts(_ snapshots: [StaySnapshot]) -> [StayGroupContext] {
        snapshots.sorted { $0.orderInTrip < $1.orderInTrip }.map(StayGroupContext.init)
    }

    // MARK: - GPS: nearest in-window stay wins

    @Test("GPS asset is assigned to the geodesic-nearest stay whose window contains it")
    func gpsNearestInWindow() {
        let a = UUID(), b = UUID()
        // Overlapping windows: both A and B contain t0+2h.
        let stays = [
            snapshot(id: a, lat: 0, lon: 0, start: Self.t0, durationHours: 3, order: 0),
            snapshot(id: b, lat: 10, lon: 10, start: Self.t0.addingTimeInterval(3600), durationHours: 3, order: 1)
        ]
        let asset = CLLocation(latitude: 9.9, longitude: 9.9)
        let when = Self.t0.addingTimeInterval(2 * 3600)

        let result = PhotoService.nearestStayID(
            assetLocation: asset,
            creationDate: when,
            sortedContexts: contexts(stays)
        )
        #expect(result == b)
    }

    @Test("GPS ties resolve to the lowest-orderInTrip stay (strict < keeps the first)")
    func gpsTieFavorsFirstOrder() {
        let a = UUID(), b = UUID()
        // Identical coordinates + overlapping windows → equal distance.
        let stays = [
            snapshot(id: b, lat: 5, lon: 5, start: Self.t0, durationHours: 3, order: 1),
            snapshot(id: a, lat: 5, lon: 5, start: Self.t0, durationHours: 3, order: 0)
        ]
        let asset = CLLocation(latitude: 5, longitude: 5)
        let when = Self.t0.addingTimeInterval(3600)

        let result = PhotoService.nearestStayID(
            assetLocation: asset,
            creationDate: when,
            sortedContexts: contexts(stays)
        )
        #expect(result == a)
    }

    @Test("GPS asset outside every stay window falls through to the mid-time fallback")
    func gpsOutsideWindowUsesFallback() {
        let a = UUID(), b = UUID()
        let stays = [
            snapshot(id: a, lat: 0, lon: 0, start: Self.t0, durationHours: 1, order: 0),
            snapshot(id: b, lat: 10, lon: 10, start: Self.t0.addingTimeInterval(3600), durationHours: 1, order: 1)
        ]
        // Far in the future — no window contains it. Even though the asset's
        // GPS sits on A, the fallback ranks by mid-time only, and B's mid-time
        // is later (closer to `when`).
        let asset = CLLocation(latitude: 0, longitude: 0)
        let when = Self.t0.addingTimeInterval(100 * 3600)

        let result = PhotoService.nearestStayID(
            assetLocation: asset,
            creationDate: when,
            sortedContexts: contexts(stays)
        )
        #expect(result == b)
    }

    // MARK: - No-GPS: first in-window stay wins

    @Test("no-GPS asset is assigned to the first in-window stay in orderInTrip order")
    func noGPSFirstInWindow() {
        let a = UUID(), b = UUID()
        // Both windows contain t0+2h; no GPS ⇒ first-in-order (A) wins,
        // regardless of coordinates.
        let stays = [
            snapshot(id: b, lat: 10, lon: 10, start: Self.t0.addingTimeInterval(3600), durationHours: 3, order: 1),
            snapshot(id: a, lat: 0, lon: 0, start: Self.t0, durationHours: 3, order: 0)
        ]
        let when = Self.t0.addingTimeInterval(2 * 3600)

        let result = PhotoService.nearestStayID(
            assetLocation: nil,
            creationDate: when,
            sortedContexts: contexts(stays)
        )
        #expect(result == a)
    }

    @Test("no-GPS asset outside every window falls back to the nearest mid-time stay")
    func noGPSOutsideWindowUsesFallback() {
        let a = UUID(), b = UUID()
        let stays = [
            snapshot(id: a, lat: 0, lon: 0, start: Self.t0, durationHours: 1, order: 0),
            snapshot(id: b, lat: 10, lon: 10, start: Self.t0.addingTimeInterval(10 * 3600), durationHours: 1, order: 1)
        ]
        // In the gap between A's window (closes t0+90min) and B's (opens
        // t0+9.5h) — no window contains it, so the mid-time fallback runs;
        // A's mid-time (t0+30min) is nearer than B's (t0+10.5h).
        let when = Self.t0.addingTimeInterval(100 * 60)

        let result = PhotoService.nearestStayID(
            assetLocation: nil,
            creationDate: when,
            sortedContexts: contexts(stays)
        )
        #expect(result == a)
    }

    // MARK: - ±30 min buffer boundary

    @Test("the ±30 min window buffer is inclusive only through its edges",
          arguments: [-1800.0, 5400.0])
    func windowBufferInclusive(edgeOffset: Double) {
        let a = UUID(), b = UUID()
        let when = Self.t0.addingTimeInterval(edgeOffset)
        let stays = [
            snapshot(id: a, lat: 0, lon: 0, start: Self.t0, durationHours: 1, order: 0),
            snapshot(id: b, lat: 0, lon: 0, start: when.addingTimeInterval(-300),
                     durationHours: 1.0 / 6, order: 1)
        ]
        // A wins by order at either buffered edge. B is centered on the
        // photo, so excluding A at equality cannot be hidden by fallback.

        let result = PhotoService.nearestStayID(
            assetLocation: nil,
            creationDate: when,
            sortedContexts: contexts(stays)
        )
        #expect(result == a)

        let outside = when.addingTimeInterval(edgeOffset < 0 ? -1 : 1)
        #expect(PhotoService.nearestStayID(
            assetLocation: nil,
            creationDate: outside,
            sortedContexts: contexts(stays)
        ) == b)
    }

    // MARK: - Degenerate input

    @Test("no stays yields no assignment")
    func emptyContextsReturnsNil() {
        let result = PhotoService.nearestStayID(
            assetLocation: CLLocation(latitude: 0, longitude: 0),
            creationDate: Self.t0,
            sortedContexts: []
        )
        #expect(result == nil)
    }

    // MARK: - Cache cap

    @Test("tripPhotoCache caps heavy entries, evicting least-recently-written; counts and epochs survive")
    func tripPhotoCacheCapEvictsOldest() {
        let service = PhotoService.shared
        // Clean baseline, and again on exit — the shared singleton's cache
        // must not leak 51 synthetic entries into other suites.
        service.invalidateAllCaches()
        defer { service.invalidateAllCaches() }

        let ids = (0 ..< PhotoService.tripPhotoCacheCap + 1).map { _ in UUID() }
        let preEvictionToken = service.invalidationToken(for: ids[0])
        for (index, id) in ids.enumerated() {
            service.storeCachedTripPhotos(tripID: id, stayShapeToken: index, groups: [])
        }

        // Oldest heavy entry evicted, the remaining cap retained.
        #expect(!service.cachedGroupsExist(for: ids[0]))
        #expect(service.cachedGroupsExist(for: ids[1]))
        #expect(service.cachedGroupsExist(for: ids[ids.count - 1]))

        // Eviction is NOT an invalidation: no epoch bump for the victim,
        // and its count mirror survives (the TripSorter/prewarm contract).
        #expect(service.invalidationToken(for: ids[0]) == preEvictionToken)
        #expect(service.cachedPhotoCount(for: ids[0]) == 0)

        // Re-writing an existing key moves it to the back of the eviction
        // order — the NEXT oldest key is the one evicted by a fresh insert.
        service.storeCachedTripPhotos(tripID: ids[1], stayShapeToken: 999, groups: [])
        service.storeCachedTripPhotos(tripID: UUID(), stayShapeToken: 1000, groups: [])
        #expect(service.cachedGroupsExist(for: ids[1]))
        #expect(!service.cachedGroupsExist(for: ids[2]))

        // Per-trip invalidation drops BOTH the heavy entry and the count
        // (unlike eviction — the data itself is stale).
        service.invalidateCache(for: ids[1])
        #expect(!service.cachedGroupsExist(for: ids[1]))
        #expect(service.cachedPhotoCount(for: ids[1]) == nil)
    }
}
