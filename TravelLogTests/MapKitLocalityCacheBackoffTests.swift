//
//  MapKitLocalityCacheBackoffTests.swift
//  TravelLogTests
//
//  Apple's `.loadingThrottled` responses were never cached, so a pass
//  over open water that saturated the 30/60 s budget re-burned the SAME
//  near-coast cells on every later pipeline pass. Throttled results now write a short-TTL backoff negative
//  (`throttleBackoffTTL`), while real "Apple answered nothing" negatives
//  keep the 7-day TTL and plain network errors stay deliberately UNcached
//  (airplane-mode-poisoning protection). These tests pin the pure
//  freshness rule and the v1-cache-row decode compatibility.
//

import Foundation
import Testing
@testable import TravelLog

@MainActor
struct MapKitLocalityCacheBackoffTests {

    private static let hour: TimeInterval = 3600

    @Test("freshness rule: backoff negatives live 12 h, real negatives 7 days, legacy rows (nil) 7 days", arguments: [
        // (isBackoff, ageHours, expectedFresh)
        (true, 1.0, true),
        (true, 11.9, true),
        (true, 12.0, false),   // backoff expires at exactly the TTL
        (true, 100.0, false),
        (false, 100.0, true),  // a real negative is still fresh at ~4 days
        (false, 167.9, true),
        (false, 168.0, false), // 7 days
        (false, 1.0, true),
    ])
    func freshnessRule(entry: (Bool, Double, Bool)) {
        let fresh = MapKitLocalityCache.negativeEntryIsFresh(
            isBackoff: entry.0,
            ageSeconds: entry.1 * Self.hour
        )
        #expect(fresh == entry.2)
    }

    @Test("legacy nil isBackoff is treated as the long-TTL kind — pre-existing negatives keep their original meaning")
    func legacyNilIsLongTTL() {
        #expect(MapKitLocalityCache.negativeEntryIsFresh(isBackoff: nil, ageSeconds: 100 * Self.hour) == true)
        #expect(MapKitLocalityCache.negativeEntryIsFresh(isBackoff: nil, ageSeconds: 169 * Self.hour) == false)
    }

    @Test("a v1 cache row (no isBackoff key) decodes cleanly with isBackoff == nil")
    func v1RowDecodeCompatibility() throws {
        // Byte-for-byte the shape the pre-2026-07-21 code persisted.
        let v1JSON = Data(
            #"{"h3Index":"8841a907adfffff","locality":null,"timestamp":1752000000,"isNegative":true}"#.utf8
        )
        let entry = try JSONDecoder().decode(MapKitLocalityCache.CachedEntry.self, from: v1JSON)
        #expect(entry.h3Index == "8841a907adfffff")
        #expect(entry.isNegative == true)
        #expect(entry.isBackoff == nil)

        // And the new shape round-trips.
        let backoff = MapKitLocalityCache.CachedEntry(
            h3Index: "8841a907adfffff",
            locality: nil,
            timestamp: 1752000000,
            isNegative: true,
            isBackoff: true
        )
        let decoded = try JSONDecoder().decode(
            MapKitLocalityCache.CachedEntry.self,
            from: JSONEncoder().encode(backoff)
        )
        #expect(decoded.isBackoff == true)
    }
}
