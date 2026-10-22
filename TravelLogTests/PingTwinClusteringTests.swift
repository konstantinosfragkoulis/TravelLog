//
//  PingTwinClusteringTests.swift
//  TravelLogTests
//
//  Equal-rank photo ping twins (two restores of one backup) are kept by the
//  photo-ping dedup and re-adopted together. Clustering takes each logical
//  ping once while settling every physical copy, and Passport counts it once.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Ping twins count once")
struct PingTwinClusteringTests {
    private static let base = Date(timeIntervalSinceReferenceDate: 830_000_000)

    @discardableResult
    private func insertPing(
        _ context: ModelContext, minutes: Double, longitude: Double, id: UUID? = nil,
        source: DataSource = .photoImport
    ) -> LocationPing {
        let ping = LocationPing(
            timestamp: Self.base.addingTimeInterval(minutes * 60),
            latitude: 44.3, longitude: longitude, horizontalAccuracy: 10,
            h3IndexRes6: H3Service.cellIndex(latitude: 44.3, longitude: longitude) ?? "",
            source: source)
        if let id { ping.id = id }
        ping.isProcessed = false
        context.insert(ping)
        return ping
    }

    @Test("re-adopted twins join one stay once: unique membership, logical count and centroid weights")
    func twinsClusterOnce() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let twin = insertPing(context, minutes: 0, longitude: 12.9)
        insertPing(context, minutes: 0, longitude: 12.9, id: twin.id)
        let other = insertPing(context, minutes: 30, longitude: 12.91)
        try context.save()

        _ = await StayClusterer(modelContainer: container).clusterUnprocessedPings()

        let read = ModelContext(container)
        let stays = try read.fetch(FetchDescriptor<Stay>())
        let stay = try #require(stays.first)
        #expect(stays.count == 1)
        #expect(stay.pingIDs == [twin.id, other.id])
        #expect(stay.pingCount == 2)
        #expect(abs(stay.centroidLongitude - 12.905) < 1e-9)
        let pings = try read.fetch(FetchDescriptor<LocationPing>())
        #expect(pings.count == 3, "both physical twins stay")
        #expect(pings.allSatisfy { $0.isProcessed })
    }

    @Test("Passport counts an import ping twin once and every other row as it is")
    func passportCountsTwinsOnce() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let twin = insertPing(context, minutes: 0, longitude: 12.9)
        insertPing(context, minutes: 0, longitude: 12.9, id: twin.id)
        insertPing(context, minutes: 30, longitude: 12.91)
        insertPing(context, minutes: 60, longitude: 12.92, source: .liveSLC)
        try context.save()

        let stats = try StatsAggregator.compute(container: container)
        #expect(stats.totalPings == 3)
        #expect(try StatsAggregator.importPingTwinSurplus(in: ModelContext(container)) == 1)
    }
}
