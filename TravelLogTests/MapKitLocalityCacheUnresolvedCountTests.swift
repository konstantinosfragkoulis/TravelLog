//
//  MapKitLocalityCacheUnresolvedCountTests.swift
//  TravelLogTests
//
//  The one-shot stay-locality backfill latches only when
//  `consumeDropCount()` is zero. Network failures, explicit throttles and
//  still-fresh throttle backoffs leave the stay unnamed, so they must count;
//  a real nameless answer (7-day negative) and `placemarkNotFound` must not,
//  or a permanently unnamed cell would block the latch forever.
//

import Foundation
import MapKit
import os
import Testing
@testable import TravelLog

@Suite(.serialized)
struct MapKitLocalityCacheUnresolvedCountTests {

    private static let offline = GeocodeResolver.Result(
        country: "Iceland",
        isoCountryCode: "IS",
        administrativeArea: nil,
        metroName: nil,
        localityName: nil,
        subLocalityName: nil,
        islandName: nil
    )
    private static let latitude = 64.7
    private static let longitude = -17.3

    private func reset() async {
        await MapKitLocalityCache.shared.clearCache()
        _ = await MapKitLocalityCache.shared.consumeDropCount()
    }

    private func enrich() async -> GeocodeResolver.Result? {
        await MapKitLocalityCache.shared.enrich(
            offline: Self.offline,
            latitude: Self.latitude,
            longitude: Self.longitude,
            allowRateLimitWait: false
        )
    }

    @Test("a network failure stays uncached and counts as unresolved")
    func networkFailureCounts() async {
        await reset()
        await MapKitLocalityCache.TestHook.$reverseGeocode.withValue({ _ in
            throw URLError(.notConnectedToInternet)
        }) {
            #expect(await enrich() == Self.offline)
        }
        #expect(await MapKitLocalityCache.shared.consumeDropCount() == 1)
        await reset()
    }

    @Test("a throttle and a later hit on its fresh backoff both count as unresolved")
    func throttleAndBackoffCount() async {
        await reset()
        await MapKitLocalityCache.TestHook.$reverseGeocode.withValue({ _ in
            throw MKError(.loadingThrottled)
        }) {
            #expect(await enrich() == Self.offline)
        }
        #expect(await MapKitLocalityCache.shared.consumeDropCount() == 1)

        await MapKitLocalityCache.TestHook.$reverseGeocode.withValue({ _ in
            Issue.record("a fresh backoff must not re-query")
            return []
        }) {
            #expect(await enrich() == Self.offline)
        }
        #expect(await MapKitLocalityCache.shared.consumeDropCount() == 1)
        await reset()
    }

    @Test("a nameless answer caches a real negative and never counts")
    func namelessAnswerDoesNotCount() async {
        await reset()
        await MapKitLocalityCache.TestHook.$reverseGeocode.withValue({ _ in [] }) {
            #expect(await enrich() == Self.offline)
        }
        #expect(await MapKitLocalityCache.shared.consumeDropCount() == 0)

        await MapKitLocalityCache.TestHook.$reverseGeocode.withValue({ _ in
            Issue.record("a fresh real negative must not re-query")
            return []
        }) {
            #expect(await enrich() == Self.offline)
        }
        #expect(await MapKitLocalityCache.shared.consumeDropCount() == 0)
        await reset()
    }

    @Test("placemarkNotFound does not count, so an unnamed cell cannot block the latch")
    func placemarkNotFoundDoesNotCount() async {
        await reset()
        await MapKitLocalityCache.TestHook.$reverseGeocode.withValue({ _ in
            throw MKError(.placemarkNotFound)
        }) {
            #expect(await enrich() == Self.offline)
        }
        #expect(await MapKitLocalityCache.shared.consumeDropCount() == 0)
        await reset()
    }

    @Test("a lookup pinned to a generation a clear has advanced sends nothing and caches nothing")
    func clearedGenerationAdmitsNoLookup() async {
        await reset()
        let pinned = await MapKitLocalityCache.shared.generation
        await MapKitLocalityCache.shared.clearCache()
        await MapKitLocalityCache.TestHook.$reverseGeocode.withValue({ _ in
            Issue.record("a lookup revoked by the clear must not reach MapKit")
            return []
        }) {
            #expect(await MapKitLocalityCache.shared.enrich(
                offline: Self.offline, latitude: Self.latitude, longitude: Self.longitude,
                allowRateLimitWait: false, generation: pinned) == Self.offline)
        }

        // No negative was cached for the cell: the current generation still queries it.
        let requests = OSAllocatedUnfairLock(initialState: 0)
        let current = await MapKitLocalityCache.shared.generation
        await MapKitLocalityCache.TestHook.$reverseGeocode.withValue({ _ in
            requests.withLock { $0 += 1 }
            return []
        }) {
            #expect(await MapKitLocalityCache.shared.enrich(
                offline: Self.offline, latitude: Self.latitude, longitude: Self.longitude,
                allowRateLimitWait: false, generation: current) == Self.offline)
        }
        #expect(requests.withLock { $0 } == 1)
        await reset()
    }
}
