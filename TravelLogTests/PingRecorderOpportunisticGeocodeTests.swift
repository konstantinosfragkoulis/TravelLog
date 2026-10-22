//
//  PingRecorderOpportunisticGeocodeTests.swift
//  TravelLogTests
//
//  Pins the opportunistic geocode lane's skip-window progression: a run of
//  unresolvable oldest pings must not stall the lane — the fetch window grows
//  with the skip set, so a resolvable row behind ANY number of leading misses
//  (below the cap) is eventually reached. Regression: with a fixed fetch
//  limit, that many leading misses filled the skip set and every later wake
//  fetched exactly the skipped rows and bailed for the rest of the process.
//

import Testing
import Foundation
import SwiftData
import CoreLocation
@testable import TravelLog

@MainActor
@Suite("PingRecorder opportunistic geocode skip window")
struct PingRecorderOpportunisticGeocodeTests {

    @Test("a resolvable ping behind 30 unresolvable ones is still reached")
    func skipWindowAdvancesPastLeadingMisses() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_696_371_200)

        // 30 oldest pings in open ocean (0,0 — misses every offline layer,
        // resolver returns nil, ping stays ungeocoded), then one in Athens.
        for i in 0..<30 {
            ctx.insert(LocationPing(
                timestamp: base.addingTimeInterval(Double(i) * 60),
                latitude: 0, longitude: 0,
                horizontalAccuracy: 10,
                h3IndexRes6: H3Service.cellIndex(latitude: 0, longitude: 0) ?? ""
            ))
        }
        let athens = LocationPing(
            timestamp: base.addingTimeInterval(31 * 60),
            latitude: 37.9838, longitude: 23.7275,
            horizontalAccuracy: 10,
            h3IndexRes6: H3Service.cellIndex(latitude: 37.9838, longitude: 23.7275) ?? ""
        )
        ctx.insert(athens)
        let athensID = athens.id
        try ctx.save()

        let recorder = PingRecorder(modelContainer: container)
        // One resolve attempt per simulated SLC wake. 31 misses-then-hit is
        // the worst case; a few extra wakes make the pin robust to ordering.
        for _ in 0..<35 {
            await recorder.tryOneOpportunisticGeocoding()
        }

        let predicate = #Predicate<LocationPing> { $0.id == athensID }
        let resolved = try #require(
            try ctx.fetch(FetchDescriptor<LocationPing>(predicate: predicate)).first)
        #expect(resolved.isGeocoded, "the lane must progress past leading unresolvable rows")
    }

    @Test("CloudKit-duplicated ping UUIDs cannot wedge the skip window")
    func duplicateUUIDsDoNotWedgeTheWindow() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_696_371_200)

        // Two PHYSICAL rows sharing one UUID (CloudKit cannot enforce
        // uniqueness) at the head of the backlog, both unresolvable, then a
        // resolvable row. A skip set keyed on `LocationPing.id` under-counts
        // the skipped rows, so a `count + 1` fetch window never grows past
        // the twins and the lane wedges — the skip set must key on physical
        // row identity.
        let sharedID = UUID()
        for i in 0..<2 {
            let twin = LocationPing(
                timestamp: base.addingTimeInterval(Double(i) * 60),
                latitude: 0, longitude: 0,
                horizontalAccuracy: 10,
                h3IndexRes6: H3Service.cellIndex(latitude: 0, longitude: 0) ?? ""
            )
            twin.id = sharedID
            ctx.insert(twin)
        }
        let athens = LocationPing(
            timestamp: base.addingTimeInterval(600),
            latitude: 37.9838, longitude: 23.7275,
            horizontalAccuracy: 10,
            h3IndexRes6: H3Service.cellIndex(latitude: 37.9838, longitude: 23.7275) ?? ""
        )
        ctx.insert(athens)
        let athensID = athens.id
        try ctx.save()

        let recorder = PingRecorder(modelContainer: container)
        for _ in 0..<5 {
            await recorder.tryOneOpportunisticGeocoding()
        }

        let predicate = #Predicate<LocationPing> { $0.id == athensID }
        let resolved = try #require(
            try ctx.fetch(FetchDescriptor<LocationPing>(predicate: predicate)).first)
        #expect(resolved.isGeocoded, "duplicate-UUID twins must not stall the lane")
    }
}
