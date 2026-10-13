//
//  StayClustererClusteringTests.swift
//  TravelLogTests
//
//  End-to-end ingestion math for StayClusterer.clusterUnprocessedPings()
//  (TravelLog/Services/StayClusterer.swift). All clustering logic — continuity-
//  anchor decision, strict distance/time-gap split, out-of-order
//  `timeSinceLast < 0` routing, the midpoint still-here extension
//  with the `maxStayExtensionSeconds` cap and `-60s` clamp, the
//  `max(endTime, ping.timestamp)` / `max(0, duration)` defence-in-depth clamps,
//  the incremental running-average centroid, per-ping `isProcessed` marking,
//  and distance-from-home recompute — is inlined in that one actor-isolated
//  loop, so these container tests are the dominant testable surface.
//
//  Assertions are restricted to DETERMINISTIC clustering geometry/time fields
//  (stay count, startTime, endTime, durationMinutes, centroid, pingCount,
//  pingIDs, distanceFromHomeKm, source, ping.isProcessed). We NEVER
//  assert on locality/subLocality/metroName/islandName/isAirport — those come
//  from Bundle.main singletons (GeocodeResolver / AirportDetector) whose output
//  is environment-dependent (resources may be absent in the test host) and
//  degrade silently to nil/false.
//
//  @MainActor because the suite constructs @Model objects (LocationPing / Stay /
//  Home) AND instantiates the @ModelActor StayClusterer; the app target compiles
//  with MainActor-by-default isolation, which makes @Model types and their
//  members MainActor-isolated.
//

import Testing
import Foundation
import SwiftData
import CoreLocation
@testable import TravelLog

@MainActor
struct StayClustererClusteringTests {

    // MARK: - Fixtures

    /// Athens anchor.
    static let athens = (lat: 37.9656, lon: 23.7020)
    /// Ioánnina, about 310 km from the Athens anchor, produces distinct stays.
    static let ioannina = (lat: 39.6628, lon: 20.8612)
    /// About 0.72 km from the Athens anchor, within the 3 km merge threshold.
    static let nearAthens = (lat: 37.9718, lon: 23.7045)

    private func makePing(t: Date, lat: Double, lon: Double,
                          source: DataSource = .liveSLC) -> LocationPing {
        LocationPing(
            timestamp: t,
            latitude: lat,
            longitude: lon,
            horizontalAccuracy: 10,
            h3IndexRes6: H3Service.cellIndex(latitude: lat, longitude: lon) ?? "",
            source: source
        )
    }

    /// Stable base instant so timestamps are deterministic and well clear of
    /// `.distantPast` (the no-anchor sentinel).
    private let base = Date(timeIntervalSince1970: 1_708_467_200) // 2024-02-20

    private func fetchStays(_ ctx: ModelContext) throws -> [Stay] {
        try ctx.fetch(FetchDescriptor<Stay>(sortBy: [SortDescriptor(\.startTime, order: .forward)]))
    }

    private func fetchPings(_ ctx: ModelContext) throws -> [LocationPing] {
        try ctx.fetch(FetchDescriptor<LocationPing>(sortBy: [SortDescriptor(\.timestamp, order: .forward)]))
    }

    // MARK: - Continuity anchor across an import

    /// A live ping arriving after historical import pings must extend the
    /// ongoing stay instead of starting a new one.
    ///
    /// `unprocessedPings` is sorted ASCENDING, so an import pass walks the
    /// historical pings first and each reassigns the continuity anchor. By the
    /// time the live ping is reached the anchor was a stay from years earlier,
    /// the gap test trivially exceeded the threshold, and the live ping forked
    /// a brand-new stay — splitting the trip the user is currently on.
    @Test("a live ping after historical import pings extends the ongoing stay, not a new one")
    func livePingAfterImportPingsExtendsOngoingStay() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let sut = StayClusterer(modelContainer: container)

        // Establish the ongoing stay from a live ping.
        ctx.insert(makePing(t: base, lat: Self.athens.lat, lon: Self.athens.lon))
        try ctx.save()
        _ = await sut.clusterUnprocessedPings()
        let ongoing = try #require(try fetchStays(ctx).first)
        let ongoingID = ongoing.id

        // Now an import lands historical pings (years earlier, elsewhere),
        // AND a live SLC wake fires at the same place an hour later.
        let historical = base.addingTimeInterval(-4 * 365 * 24 * 3600)
        ctx.insert(makePing(t: historical, lat: Self.ioannina.lat,
                            lon: Self.ioannina.lon, source: .photoImport))
        ctx.insert(makePing(t: historical.addingTimeInterval(600),
                            lat: Self.ioannina.lat, lon: Self.ioannina.lon,
                            source: .photoImport))
        ctx.insert(makePing(t: base.addingTimeInterval(3600),
                            lat: Self.nearAthens.lat, lon: Self.nearAthens.lon))
        try ctx.save()

        _ = await sut.clusterUnprocessedPings()

        let stays = try fetchStays(ctx)
        // Exactly two: the historical import stay, and the ongoing one — NOT
        // a third forked from the live ping.
        #expect(stays.count == 2)
        let survivor = try #require(stays.first { $0.id == ongoingID })
        #expect(survivor.pingCount == 2)
        #expect(survivor.endTime == base.addingTimeInterval(3600))
    }

    // MARK: - Empty / single

    @Test("empty context → 0 stays created and none exist (empty-unprocessed guard)")
    func emptyContextCreatesNoStays() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let sut = StayClusterer(modelContainer: container)

        let created = await sut.clusterUnprocessedPings()
        #expect(created == 0)
        #expect(try fetchStays(ctx).isEmpty)
    }

    @Test("single ping → one stay; startTime==endTime==ping.timestamp, pingCount 1, centroid == ping, duration 0")
    func singlePingCreatesOneStay() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let ping = makePing(t: base, lat: Self.athens.lat, lon: Self.athens.lon)
        ctx.insert(ping)
        let pingID = ping.id
        try ctx.save()

        let sut = StayClusterer(modelContainer: container)
        let created = await sut.clusterUnprocessedPings()

        #expect(created == 1)
        let stays = try fetchStays(ctx)
        #expect(stays.count == 1)
        let stay = try #require(stays.first)
        #expect(stay.startTime == base)
        #expect(stay.endTime == base)
        #expect(stay.pingCount == 1)
        #expect(stay.centroidLatitude == Self.athens.lat)
        #expect(stay.centroidLongitude == Self.athens.lon)
        #expect(stay.pingIDs == [pingID])
        #expect(stay.durationMinutes == 0)
    }

    // MARK: - Merge vs split

    @Test("two nearby pings within the time gap merge into one stay (pingCount 2, endTime advances)")
    func twoNearbyPingsWithinTimeGapMergeIntoOneStay() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let t0 = base
        let t1 = base.addingTimeInterval(30 * 60) // +30 min (< 4h), < 3km
        let p0 = makePing(t: t0, lat: Self.athens.lat, lon: Self.athens.lon)
        let p1 = makePing(t: t1, lat: Self.nearAthens.lat, lon: Self.nearAthens.lon)
        ctx.insert(p0); ctx.insert(p1)
        let ids = Set([p0.id, p1.id])
        try ctx.save()

        let sut = StayClusterer(modelContainer: container)
        let created = await sut.clusterUnprocessedPings()

        #expect(created == 1)
        let stays = try fetchStays(ctx)
        #expect(stays.count == 1)
        let stay = try #require(stays.first)
        #expect(stay.pingCount == 2)
        #expect(stay.endTime == t1)
        #expect(stay.durationMinutes == 30)
        #expect(Set(stay.pingIDs) == ids)
    }

    @Test("far-apart pings (Athens then Ioánnina, about 310 km) start separate stays")
    func farApartPingsStartSeparateStays() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let p0 = makePing(t: base, lat: Self.athens.lat, lon: Self.athens.lon)
        let p1 = makePing(t: base.addingTimeInterval(30 * 60),
                          lat: Self.ioannina.lat, lon: Self.ioannina.lon)
        ctx.insert(p0); ctx.insert(p1)
        try ctx.save()

        let sut = StayClusterer(modelContainer: container)
        let created = await sut.clusterUnprocessedPings()

        #expect(created == 2)
        let stays = try fetchStays(ctx)
        #expect(stays.count == 2)
        #expect(stays.allSatisfy { $0.pingCount == 1 })
        let first = try #require(stays.first)
        let last = try #require(stays.last)
        #expect(first.centroidLatitude == Self.athens.lat)
        #expect(last.centroidLatitude == Self.ioannina.lat)
    }

    @Test("same coord but > 4h apart starts a new stay (time-gap branch fires with distance ~0)")
    func timeGapBeyondFourHoursStartsNewStay() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let p0 = makePing(t: base, lat: Self.athens.lat, lon: Self.athens.lon)
        let p1 = makePing(t: base.addingTimeInterval(5 * 60 * 60), // +5h > 4h
                          lat: Self.athens.lat, lon: Self.athens.lon)
        ctx.insert(p0); ctx.insert(p1)
        try ctx.save()

        let sut = StayClusterer(modelContainer: container)
        let created = await sut.clusterUnprocessedPings()

        #expect(created == 2)
        #expect(try fetchStays(ctx).count == 2)
    }

    @Test("time gap exactly at threshold (==4h, not >4h) extends — predicate is strict >")
    func timeGapExactlyAtThresholdExtends() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let p0 = makePing(t: base, lat: Self.athens.lat, lon: Self.athens.lon)
        let p1 = makePing(t: base.addingTimeInterval(StayClusterer.timeGapThresholdSeconds),
                          lat: Self.athens.lat, lon: Self.athens.lon)
        ctx.insert(p0); ctx.insert(p1)
        try ctx.save()

        let sut = StayClusterer(modelContainer: container)
        let created = await sut.clusterUnprocessedPings()

        #expect(created == 1)
        let stays = try fetchStays(ctx)
        #expect(stays.count == 1)
        #expect(try #require(stays.first).pingCount == 2)
    }

    @Test("distance just under 3 km within the time window stays in one stay (distance predicate is strict >)")
    func distanceJustBelowThresholdExtends() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // About 2.9 km north of the Athens anchor, safely inside the strict < boundary
        // given CLLocation float precision (1 deg lat ≈ 111 km → 0.026 deg ≈ 2.9 km).
        let p0 = makePing(t: base, lat: Self.athens.lat, lon: Self.athens.lon)
        let p1 = makePing(t: base.addingTimeInterval(10 * 60),
                          lat: Self.athens.lat + 0.026, lon: Self.athens.lon)
        ctx.insert(p0); ctx.insert(p1)
        try ctx.save()

        // Sanity: the geodesic distance is < 3000 m so the extend path is taken.
        let d = CLLocation(latitude: Self.athens.lat, longitude: Self.athens.lon)
            .distance(from: CLLocation(latitude: Self.athens.lat + 0.026, longitude: Self.athens.lon))
        #expect(d < StayClusterer.distanceThresholdMeters)

        let sut = StayClusterer(modelContainer: container)
        let created = await sut.clusterUnprocessedPings()

        #expect(created == 1)
        #expect(try #require(try fetchStays(ctx).first).pingCount == 2)
    }

    // MARK: - Centroid / counts

    @Test("centroid is the running average of folded ping coords (incremental mean over a fresh stay == plain mean)")
    func centroidIsRunningAverageOfPingCoords() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let lats = [37.9656, 37.9668, 37.9678]
        let lons = [23.7020, 23.7035, 23.7045]
        for i in 0..<3 {
            ctx.insert(makePing(t: base.addingTimeInterval(Double(i) * 60),
                                lat: lats[i], lon: lons[i]))
        }
        try ctx.save()

        let sut = StayClusterer(modelContainer: container)
        let created = await sut.clusterUnprocessedPings()

        #expect(created == 1)
        let stay = try #require(try fetchStays(ctx).first)
        let meanLat = lats.reduce(0, +) / 3.0
        let meanLon = lons.reduce(0, +) / 3.0
        #expect(abs(stay.centroidLatitude - meanLat) < 1e-9)
        #expect(abs(stay.centroidLongitude - meanLon) < 1e-9)
        #expect(stay.centroidLatitude >= lats.min()! && stay.centroidLatitude <= lats.max()!)
        #expect(stay.centroidLongitude >= lons.min()! && stay.centroidLongitude <= lons.max()!)
    }

    @Test("pingCount == pingIDs.count == number of pings folded into the stay")
    func pingCountMatchesAccumulatedPingIDs() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        for i in 0..<4 {
            ctx.insert(makePing(t: base.addingTimeInterval(Double(i) * 5 * 60),
                                lat: Self.athens.lat, lon: Self.athens.lon))
        }
        try ctx.save()

        let sut = StayClusterer(modelContainer: container)
        let created = await sut.clusterUnprocessedPings()

        #expect(created == 1)
        let stay = try #require(try fetchStays(ctx).first)
        #expect(stay.pingCount == 4)
        #expect(stay.pingIDs.count == 4)
        #expect(stay.pingCount == stay.pingIDs.count)
    }

    // MARK: - Processing flags / idempotence

    @Test("after a run every ping is marked isProcessed == true")
    func allProcessedPingsAreMarked() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        ctx.insert(makePing(t: base, lat: Self.athens.lat, lon: Self.athens.lon))
        ctx.insert(makePing(t: base.addingTimeInterval(60), lat: Self.athens.lat, lon: Self.athens.lon))
        try ctx.save()

        let sut = StayClusterer(modelContainer: container)
        _ = await sut.clusterUnprocessedPings()

        #expect(try fetchPings(ctx).allSatisfy { $0.isProcessed })
    }

    @Test("re-running ignores already-processed pings (idempotent: second run hits the empty-unprocessed guard)")
    func alreadyProcessedPingsAreIgnored() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        ctx.insert(makePing(t: base, lat: Self.athens.lat, lon: Self.athens.lon))
        try ctx.save()

        let sut = StayClusterer(modelContainer: container)
        let first = await sut.clusterUnprocessedPings()
        #expect(first == 1)

        let second = await sut.clusterUnprocessedPings()
        #expect(second == 0)
        #expect(try fetchStays(ctx).count == 1)
    }

    @Test("a second new nearby ping extends the open stay via the cross-run continuity anchor (0 new stays)")
    func secondRunOfNewPingExtendsViaContinuityAnchor() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let p0 = makePing(t: base, lat: Self.athens.lat, lon: Self.athens.lon)
        ctx.insert(p0)
        try ctx.save()

        let sut = StayClusterer(modelContainer: container)
        #expect(await sut.clusterUnprocessedPings() == 1)

        // A second nearby Athens ping 1h later, inserted AFTER the first run.
        let p1 = makePing(t: base.addingTimeInterval(60 * 60),
                          lat: Self.nearAthens.lat, lon: Self.nearAthens.lon)
        ctx.insert(p1)
        try ctx.save()

        let created2 = await sut.clusterUnprocessedPings()
        #expect(created2 == 0) // re-anchors on the open stay and extends it
        let stays = try fetchStays(ctx)
        #expect(stays.count == 1)
        let stay = try #require(stays.first)
        #expect(stay.pingCount == 2)
        #expect(stay.endTime == base.addingTimeInterval(60 * 60))
    }

    // MARK: - Out-of-order

    @Test("out-of-order earlier ping does NOT move the existing stay's endTime backward (timeSinceLast < 0 → fresh stay)")
    func outOfOrderEarlierPingDoesNotMoveEndTimeBackward() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // Anchor stay built from a ping at T (= base).
        ctx.insert(makePing(t: base, lat: Self.athens.lat, lon: Self.athens.lon))
        try ctx.save()
        let sut = StayClusterer(modelContainer: container)
        #expect(await sut.clusterUnprocessedPings() == 1)
        let anchorEndTimeBefore = try #require(try fetchStays(ctx).first).endTime

        // A NEW unprocessed ping at the SAME place but timestamped BEFORE T.
        ctx.insert(makePing(t: base.addingTimeInterval(-3 * 60 * 60),
                            lat: Self.athens.lat, lon: Self.athens.lon))
        try ctx.save()

        let created2 = await sut.clusterUnprocessedPings()
        #expect(created2 == 1) // routed to its own historical stay

        let stays = try fetchStays(ctx)
        #expect(stays.count == 2)
        // Every stay is well-formed; the original anchor's endTime never went backward.
        #expect(stays.allSatisfy { $0.endTime >= $0.startTime })
        let original = try #require(stays.max(by: { $0.startTime < $1.startTime }))
        #expect(original.endTime == anchorEndTimeBefore)
    }

    @Test("no stay ever has a negative duration across a mixed batch with an out-of-order ping")
    func noStayEverHasNegativeDuration() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        ctx.insert(makePing(t: base, lat: Self.athens.lat, lon: Self.athens.lon))
        try ctx.save()
        let sut = StayClusterer(modelContainer: container)
        _ = await sut.clusterUnprocessedPings()

        // Mixed second batch: an earlier ping and a later ping.
        ctx.insert(makePing(t: base.addingTimeInterval(-2 * 60 * 60),
                            lat: Self.ioannina.lat, lon: Self.ioannina.lon))
        ctx.insert(makePing(t: base.addingTimeInterval(30 * 60),
                            lat: Self.athens.lat, lon: Self.athens.lon))
        try ctx.save()
        _ = await sut.clusterUnprocessedPings()

        let stays = try fetchStays(ctx)
        #expect(stays.allSatisfy { $0.endTime >= $0.startTime })
        #expect(stays.allSatisfy { $0.durationMinutes >= 0 })
    }

    // MARK: - Still-here midpoint extension + cap

    @Test("still-here midpoint extension is capped at 12h for a multi-year gap (cap regression guard)")
    func stillHereMidpointExtensionIsCappedForLargeGap() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let t1 = base
        // A far-away ping YEARS later (> 2 * maxStayExtensionSeconds, and ≫ 4h).
        let yearsLater = base.addingTimeInterval(3 * 365 * 24 * 60 * 60)
        ctx.insert(makePing(t: t1, lat: Self.athens.lat, lon: Self.athens.lon))
        ctx.insert(makePing(t: yearsLater, lat: Self.ioannina.lat, lon: Self.ioannina.lon))
        try ctx.save()

        let sut = StayClusterer(modelContainer: container)
        let created = await sut.clusterUnprocessedPings()
        #expect(created == 2)

        let stays = try fetchStays(ctx)
        let stayA = try #require(stays.first) // earliest startTime
        // A single sparse ping cannot inflate A's endTime by more than the cap.
        #expect(stayA.endTime.timeIntervalSince(t1) <= StayClusterer.maxStayExtensionSeconds)
        #expect(stayA.endTime >= stayA.startTime)
    }

    @Test("still-here midpoint uses gap/2 for a small gap (uncapped) and never past newPing - 60s")
    func stillHereMidpointUsesHalfGapForSmallGap() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let t1 = base
        // Far away (distance branch) but only +2h (< 4h window) → gap/2 = 1h, uncapped.
        let t2 = base.addingTimeInterval(2 * 60 * 60)
        ctx.insert(makePing(t: t1, lat: Self.athens.lat, lon: Self.athens.lon))
        ctx.insert(makePing(t: t2, lat: Self.ioannina.lat, lon: Self.ioannina.lon))
        try ctx.save()

        let sut = StayClusterer(modelContainer: container)
        #expect(await sut.clusterUnprocessedPings() == 2)

        let stays = try fetchStays(ctx)
        let stayA = try #require(stays.first)
        // midpoint = t1 + min(7200/2, 43200) = t1 + 3600
        #expect(abs(stayA.endTime.timeIntervalSince(t1) - 3600) < 1.0)
        // never past newPing.timestamp - 60
        #expect(stayA.endTime <= t2.addingTimeInterval(-60))
    }

    @Test("closed stay's endTime never overlaps the new stay's start (clamped to newPing - 60s)")
    func midpointNeverExceedsNewPingMinusOneMinute() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let t1 = base
        // Gap where gap/2 would land within 60s of the new ping (gap = 2 min → gap/2 = 60s),
        // far away so the distance branch closes A. midpoint = t1 + 60, clamp = (t1+120) - 60 = t1+60.
        let t2 = base.addingTimeInterval(120)
        ctx.insert(makePing(t: t1, lat: Self.athens.lat, lon: Self.athens.lon))
        ctx.insert(makePing(t: t2, lat: Self.ioannina.lat, lon: Self.ioannina.lon))
        try ctx.save()

        let sut = StayClusterer(modelContainer: container)
        #expect(await sut.clusterUnprocessedPings() == 2)

        let stays = try fetchStays(ctx)
        let closed = try #require(stays.first { $0.startTime == t1 })
        let newStay = try #require(stays.first { $0.startTime == t2 })
        #expect(closed.endTime <= newStay.startTime.addingTimeInterval(-60))
    }

    /// Agios Dimitrios, about 4.5 km from the Athens anchor.
    static let agiosDimitrios = (lat: 37.9333, lon: 23.7336)
    /// Néa Pentéli, about 17.3 km from the Athens anchor and farther from Agios Dimitrios.
    static let neaPenteli = (lat: 38.0598, lon: 23.8596)

    @Test("a historical import stay's still-here extension stops before the next existing stay")
    func historicalExtensionStopsBeforeNextExistingStay() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let sut = StayClusterer(modelContainer: container)
        let hour: TimeInterval = 3600
        let day0 = base

        // Live history: A at Athens, B at Agios Dimitrios, anchor C at Athens five days later.
        ctx.insert(makePing(t: day0.addingTimeInterval(10 * hour), lat: Self.athens.lat, lon: Self.athens.lon))
        ctx.insert(makePing(t: day0.addingTimeInterval(11 * hour), lat: Self.athens.lat, lon: Self.athens.lon))
        ctx.insert(makePing(t: day0.addingTimeInterval(15 * hour), lat: Self.agiosDimitrios.lat, lon: Self.agiosDimitrios.lon))
        ctx.insert(makePing(t: day0.addingTimeInterval(18 * hour), lat: Self.agiosDimitrios.lat, lon: Self.agiosDimitrios.lon))
        ctx.insert(makePing(t: day0.addingTimeInterval(20 * hour), lat: Self.agiosDimitrios.lat, lon: Self.agiosDimitrios.lon))
        ctx.insert(makePing(t: day0.addingTimeInterval(5 * 24 * hour), lat: Self.athens.lat, lon: Self.athens.lon))
        try ctx.save()
        #expect(await sut.clusterUnprocessedPings() == 3)
        let stayB = try #require(try fetchStays(ctx).first {
            $0.startTime == day0.addingTimeInterval(15 * hour)
        })
        let bStart = stayB.startTime
        let anchor = try #require(try fetchStays(ctx).last)
        let anchorEnd = anchor.endTime

        // Unattached photo pings behind the anchor: p1 between A and B, p2 two days later.
        let p1 = makePing(t: day0.addingTimeInterval(12 * hour), lat: Self.neaPenteli.lat,
                          lon: Self.neaPenteli.lon, source: .photoImport)
        let p1ID = p1.id
        ctx.insert(p1)
        ctx.insert(makePing(t: day0.addingTimeInterval(2 * 24 * hour + 12 * hour),
                            lat: Self.ioannina.lat, lon: Self.ioannina.lon,
                            source: .photoImport))
        try ctx.save()
        _ = await sut.clusterUnprocessedPings()

        let stays = try fetchStays(ctx)
        let historical = try #require(stays.first { $0.pingIDs.contains(p1ID) })
        #expect(historical.endTime <= bStart.addingTimeInterval(-60))
        #expect(historical.endTime >= historical.startTime)
        #expect(anchor.endTime == anchorEnd)
    }

    @Test("a historical import stay with no existing stay before the next ping keeps the capped extension")
    func historicalExtensionWithoutExistingStayKeepsCap() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let sut = StayClusterer(modelContainer: container)
        let hour: TimeInterval = 3600

        ctx.insert(makePing(t: base.addingTimeInterval(5 * 24 * hour), lat: Self.athens.lat, lon: Self.athens.lon))
        try ctx.save()
        #expect(await sut.clusterUnprocessedPings() == 1)

        let p1 = makePing(t: base.addingTimeInterval(12 * hour), lat: Self.neaPenteli.lat,
                          lon: Self.neaPenteli.lon, source: .photoImport)
        let p1ID = p1.id
        ctx.insert(p1)
        ctx.insert(makePing(t: base.addingTimeInterval(2 * 24 * hour + 12 * hour),
                            lat: Self.ioannina.lat, lon: Self.ioannina.lon,
                            source: .photoImport))
        try ctx.save()
        _ = await sut.clusterUnprocessedPings()

        let historical = try #require(try fetchStays(ctx).first { $0.pingIDs.contains(p1ID) })
        #expect(historical.endTime == p1.timestamp.addingTimeInterval(StayClusterer.maxStayExtensionSeconds))
    }

    @Test("each historical stay in one walk stops before its own next existing stay, never one it starts on")
    func historicalExtensionsStopBeforeEachOwnNextExistingStay() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let sut = StayClusterer(modelContainer: container)
        let hour: TimeInterval = 3600
        let day: TimeInterval = 24 * hour
        func at(_ d: Double, _ h: Double) -> Date { base.addingTimeInterval(d * day + h * hour) }

        // Live history: one Athens stay at 10:00 on days 0 through 6; day 6 is the anchor.
        for d in 0...6 {
            ctx.insert(makePing(t: at(Double(d), 10), lat: Self.athens.lat, lon: Self.athens.lon))
        }
        try ctx.save()
        #expect(await sut.clusterUnprocessedPings() == 7)
        let anchor = try #require(try fetchStays(ctx).last)
        #expect(anchor.startTime == at(6, 10))
        let anchorEnd = anchor.endTime

        // Photo pings behind the anchor; the day 3 one starts exactly on an existing stay.
        let photos = [at(0, 23), at(3, 10), at(4, 23), at(5, 23)].map {
            makePing(t: $0, lat: Self.neaPenteli.lat, lon: Self.neaPenteli.lon, source: .photoImport)
        }
        let photoIDs = photos.map(\.id)
        photos.forEach { ctx.insert($0) }
        try ctx.save()
        #expect(await sut.clusterUnprocessedPings() == 4)

        let stays = try fetchStays(ctx)
        func historical(_ index: Int) throws -> Stay {
            try #require(stays.first { $0.pingIDs.contains(photoIDs[index]) })
        }
        // Clamped by the day 1 stay, not by a later one.
        #expect(try historical(0).endTime == at(1, 10).addingTimeInterval(-60))
        // A stay starting on the day 3 stay looks past it to day 4, so the capped midpoint stands.
        #expect(try historical(1).endTime == at(3, 22))
        // Clamped by the day 5 stay, not by the day 1 stay the walk passed long ago.
        #expect(try historical(2).endTime == at(5, 10).addingTimeInterval(-60))
        // The last historical stay is never closed.
        #expect(try historical(3).endTime == at(5, 23))
        #expect(anchor.endTime == anchorEnd)
    }

    @Test("the next existing start is the first strictly later one, as a linear scan finds it")
    func firstStartMatchesLinearScan() {
        // Ascending starts ten minutes apart, each repeated zero, one or two times.
        var starts: [Date] = []
        for i in 0..<60 {
            for _ in 0..<(i % 3) { starts.append(base.addingTimeInterval(Double(i) * 600)) }
        }
        let queries = stride(from: -600.0, through: 61 * 600, by: 300).map { base.addingTimeInterval($0) }
        let collections: [ArraySlice<Date>] = [
            ArraySlice(starts), starts.dropFirst(7), starts.prefix(1), ArraySlice([]),
        ]
        for collection in collections {
            for query in queries {
                #expect(StayClusterer.firstStart(after: query, in: collection)
                        == collection.first(where: { $0 > query }))
            }
        }
    }

    @Test("finding the next existing start reads a logarithmic number of starts")
    func firstStartReadsLogarithmically() {
        let count = 100_000
        let counter = ReadCounter()
        let starts = CountingDates(
            dates: (0..<count).map { base.addingTimeInterval(Double($0) * 60) }, counter: counter)
        // floor(log2(n)) + 1 probes, plus reading the answer.
        let bound = Int(log2(Double(count))) + 2
        for offset in [-60.0, 0, 30, Double(count / 2) * 60, Double(count - 2) * 60, Double(count) * 60] {
            counter.reads = 0
            _ = StayClusterer.firstStart(after: base.addingTimeInterval(offset), in: starts)
            #expect(counter.reads <= bound)
        }
    }

    // MARK: - Statistics

    @Test("totalStayCount() matches the fetched Stay count (including the 0 case)")
    func totalStayCountReflectsCreatedStays() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let sut = StayClusterer(modelContainer: container)

        #expect(await sut.totalStayCount() == 0)

        // Three distinct-location pings → three stays.
        ctx.insert(makePing(t: base, lat: Self.athens.lat, lon: Self.athens.lon))
        ctx.insert(makePing(t: base.addingTimeInterval(60),
                            lat: Self.ioannina.lat, lon: Self.ioannina.lon))
        ctx.insert(makePing(t: base.addingTimeInterval(120),
                            lat: 37.6826, lon: 26.8319)) // Pagóndas, far from both
        try ctx.save()
        _ = await sut.clusterUnprocessedPings()

        let fetched = try fetchStays(ctx).count
        #expect(await sut.totalStayCount() == fetched)
    }

    // MARK: - Source propagation

    @Test("stays normalize raw live sources and preserve import sources")
    func stayNormalizesRawLiveSourcesAndPreservesImportSources() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // Far-apart seeds with different provenance each map to their own stay.
        ctx.insert(makePing(t: base, lat: Self.athens.lat, lon: Self.athens.lon,
                            source: .liveSLC))
        ctx.insert(makePing(t: base.addingTimeInterval(60),
                            lat: Self.ioannina.lat, lon: Self.ioannina.lon,
                            source: .foregroundStream))
        ctx.insert(makePing(t: base.addingTimeInterval(120),
                            lat: 37.6826, lon: 26.8319,
                            source: .photoImport))
        try ctx.save()

        let sut = StayClusterer(modelContainer: container)
        #expect(await sut.clusterUnprocessedPings() == 3)

        let stays = try fetchStays(ctx)
        let athensStay = try #require(stays.first { $0.centroidLatitude == Self.athens.lat })
        let ioanninaStay = try #require(stays.first { $0.centroidLatitude == Self.ioannina.lat })
        let pagondasStay = try #require(stays.first { $0.centroidLatitude == 37.6826 })
        #expect(athensStay.source == .liveSLC)
        #expect(ioanninaStay.source == .liveSLC)
        #expect(pagondasStay.source == .photoImport)
    }

    // MARK: - Distance from home

    @Test("with no Home rows, distanceFromHomeKm == greatestFiniteMagnitude (no-home sentinel)")
    func distanceFromHomeIsGreatestFiniteWhenNoHomes() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        ctx.insert(makePing(t: base, lat: Self.athens.lat, lon: Self.athens.lon))
        try ctx.save()

        let sut = StayClusterer(modelContainer: container)
        _ = await sut.clusterUnprocessedPings()

        let stay = try #require(try fetchStays(ctx).first)
        #expect(stay.distanceFromHomeKm == Double.greatestFiniteMagnitude)
    }

    @Test("distanceFromHomeKm uses the active home at stay time — ~300 km for a far ping, ~0 km at the home coord")
    func distanceFromHomeUsesActiveHomeAtStayTime() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // Active home at Athens: started before the ping, endedAt nil (current).
        let home = Home(label: "Athens Home",
                        latitude: Self.athens.lat, longitude: Self.athens.lon,
                        startedAt: base.addingTimeInterval(-24 * 60 * 60))
        ctx.insert(home)

        // A far ping (Ioánnina, about 310 km) and a ping AT the home coord, far enough
        // in time/space apart to map to two distinct stays.
        ctx.insert(makePing(t: base, lat: Self.ioannina.lat, lon: Self.ioannina.lon))
        ctx.insert(makePing(t: base.addingTimeInterval(60),
                            lat: Self.athens.lat, lon: Self.athens.lon))
        try ctx.save()

        let sut = StayClusterer(modelContainer: container)
        #expect(await sut.clusterUnprocessedPings() == 2)

        let stays = try fetchStays(ctx)
        let farStay = try #require(stays.first { $0.centroidLatitude == Self.ioannina.lat })
        let homeStay = try #require(stays.first { $0.centroidLatitude == Self.athens.lat })
        #expect(abs(farStay.distanceFromHomeKm - 300) < 50) // ~300 km, generous tolerance
        #expect(homeStay.distanceFromHomeKm < 1.0) // ~0 km at the home coordinate
    }
}

/// Counts element reads so a lookup's cost is asserted without a clock.
private final class ReadCounter {
    var reads = 0
}

private struct CountingDates: RandomAccessCollection {
    let dates: [Date]
    let counter: ReadCounter
    var startIndex: Int { dates.startIndex }
    var endIndex: Int { dates.endIndex }
    subscript(position: Int) -> Date {
        counter.reads += 1
        return dates[position]
    }
}
