//
//  ImportPingMaintenanceTests.swift
//  TravelLogTests
//
//  The photo-import-ping maintenance pass
//  (`PhotoImportPingDeduplicator.deduplicateAll`): Phase A deduplication,
//  Phase B reconciliation and its title lifecycle, the orphan sweep and its
//  completion report, and parity with the model-reading scan.
//
//  Phase A of the CloudKit-convergence deduplicator is a PURE in-memory pass over every `LocationPing` whose
//  `sourceRaw == "photoImport"`: sort deterministically by
//  `(timestamp, id.uuidString)`, then slide a `±90 s` / `≤200 m` window and
//  delete the later-by-sort member of each duplicate pair. The deterministic
//  sort + `id.uuidString` tiebreak are what let two CloudKit devices compute
//  the SAME to-delete set, so deletes are idempotent across the store.
//
//  The Phase A tests pin its observable contract: which pings get deleted and
//  which survive, the strict-greater `+90 s` time boundary, the `≤200 m`
//  spatial threshold, the smaller-uuid tiebreak on a timestamp tie,
//  order-independence (shuffled inserts + reused ids converge to the same
//  survivors), run-twice idempotence, and the `sourceRaw == "photoImport"`
//  filter (live SLC pings are never considered).
//
//  Phase B is asserted below via the `bypassSingleFlightForTesting` seam.
//
//  `@MainActor` because the app target compiles MainActor-by-default, which
//  makes `@Model` types (LocationPing) MainActor-isolated.
//

import Testing
import Foundation
import SwiftData
import CoreLocation
@testable import TravelLog

/// SplitMix64, so the parity corpus is the same on every run.
private struct PingCorpusRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// Every call passes `bypassSingleFlightForTesting: true`:
// deduplicateAll's process-global static `isRunning` latch is shared with
// every OTHER parallel suite in the test process, so even with `.serialized`
// inside this suite, a concurrent suite's dedup hold made calls here no-op
// and left duplicate rows in the test store.
// Distinct in-memory stores cannot contend, so the latch is bypassed.
// `.serialized` is kept: Phase B still awaits the shared
// AppDelegate.photoImportService singleton.
@Suite(.serialized)
@MainActor
struct ImportPingMaintenanceTests {

    // MARK: - Fixtures

    /// Reference-date-anchored instant so the `(timestamp, id.uuidString)`
    /// sort the dedup depends on never flips under timezone/DST skew. `t(0)`
    /// starts the fixture clock; offsets are plain seconds.
    private func t(_ secondsFromRef: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: secondsFromRef + 4_838_400)
    }

    /// Athens-ish anchor. Real cross-device duplicates of the same PHAsset
    /// share EXIF coords exactly; we vary by a controlled meter offset.
    nonisolated static let baseLat: Double = 37.9838
    nonisolated static let baseLon: Double = 23.7275

    /// Shift `baseLon` east by ~`meters` at `baseLat`. One degree of longitude
    /// at 37.98°N is ~87_900 m, so `meters / 87_900` degrees. Used to place a
    /// second ping a known geodesic distance from the anchor for the ≤200 m vs
    /// >200 m threshold tests. We assert the realized distance with a tolerance
    /// band rather than trusting the approximation exactly.
    private func lonOffsetEastMeters(_ meters: Double) -> Double {
        let metersPerDegreeLon = 111_320.0 * cos(Self.baseLat * .pi / 180.0)
        return Self.baseLon + meters / metersPerDegreeLon
    }

    /// Build a photo-import ping at the anchor (override lat/lon for spatial
    /// tests). `source` defaults to `.photoImport`; the only source Phase A
    /// considers; but is overridable so we can seed live pings as noise.
    private func makePing(
        at time: Date,
        lat: Double = Self.baseLat,
        lon: Double = Self.baseLon,
        source: DataSource = .photoImport
    ) -> LocationPing {
        LocationPing(
            timestamp: time,
            latitude: lat,
            longitude: lon,
            horizontalAccuracy: 10,
            h3IndexRes6: "861f8d4ffffffff",
            source: source
        )
    }

    /// Re-fetch through a FRESH context so we observe what Phase A committed to
    /// the shared store, not the seeding graph.
    private func fetchAll(_ container: ModelContainer) throws -> [LocationPing] {
        let ctx = ModelContext(container)
        return try ctx.fetch(FetchDescriptor<LocationPing>())
    }

    private func fetchImports(_ container: ModelContainer) throws -> [LocationPing] {
        try fetchAll(container).filter { $0.sourceRaw == DataSource.photoImport.rawValue }
    }

    // MARK: - Guard / no-op paths (return BEFORE any deletion)

    @Test("idle maintenance restores missing map visits without changing existing remote evidence")
    func missingHexVisitsRestoreConservatively() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        #expect(container.configurations.allSatisfy { $0.cloudKitContainerIdentifier == nil })
        let context = ModelContext(container)
        let ping = makePing(at: t(50_000))
        ping.h3IndexRes6 = try #require(H3Service.cellIndex(latitude: ping.latitude, longitude: ping.longitude))
        #expect(H3Service.centerCoordinate(for: ping.h3IndexRes6) != nil)
        context.insert(ping)
        let second = makePing(at: t(60_000))
        second.latitude = 40.6401
        second.h3IndexRes6 = try #require(H3Service.cellIndex(latitude: second.latitude, longitude: second.longitude))
        context.insert(second)
        let remote = HexVisit(h3Index: second.h3IndexRes6, firstVisited: t(1),
            centerLatitude: second.latitude, centerLongitude: second.longitude)
        remote.lastVisited = t(90_000)
        remote.visitCount = 99
        context.insert(remote)
        try context.save()
        for _ in 0..<2 {
            await PhotoImportPingDeduplicator.deduplicateAll(modelContainer: container,
                bypassSingleFlightForTesting: true)
        }
        let rows = try ModelContext(container).fetch(FetchDescriptor<HexVisit>())
        #expect(rows.count == 2)
        let repaired = try #require(rows.first { $0.h3Index == ping.h3IndexRes6 })
        #expect(repaired.firstVisited == ping.timestamp)
        #expect(repaired.lastVisited == ping.timestamp)
        #expect(repaired.visitCount == 1)
        let preserved = try #require(rows.first { $0.h3Index == second.h3IndexRes6 })
        #expect(preserved.firstVisited == t(1))
        #expect(preserved.lastVisited == t(90_000))
        #expect(preserved.visitCount == 99)
    }

    private func repairContainer(cloud: Bool = false) throws -> ModelContainer {
        let schema = Schema(versionedSchema: CurrentTravelLogSchema.self)
        let configuration = ModelConfiguration(schema: schema, url: TestSupport.temporaryStoreURL(),
            cloudKitDatabase: cloud ? .private("iCloud.com.kfragkoulis.TravelLog") : .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    @Test("launch repair is additive, preserves existing evidence, and completes only once")
    func oneTimeLaunchRepair() async throws {
        let container = try repairContainer()
        let suite = "hex-repair-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = ModelContext(container)
        // Real cells: the restore derives the row centre from the H3 index.
        let baseCell = try #require(H3Service.cellIndex(latitude: Self.baseLat, longitude: Self.baseLon))
        let first = makePing(at: t(10))
        first.h3IndexRes6 = baseCell
        first.isProcessed = true
        let duplicate = makePing(at: t(20))
        duplicate.h3IndexRes6 = baseCell
        duplicate.isProcessed = true
        let existingPing = makePing(at: t(30), lat: 40.6401)
        existingPing.h3IndexRes6 = try #require(H3Service.cellIndex(latitude: 40.6401, longitude: Self.baseLon))
        for ping in [first, duplicate, existingPing] { context.insert(ping) }
        let existing = HexVisit(h3Index: existingPing.h3IndexRes6, firstVisited: t(1),
            centerLatitude: 40.6401, centerLongitude: Self.baseLon)
        existing.lastVisited = t(100)
        existing.visitCount = 99
        context.insert(existing)
        try context.save()
        let gate = PipelineGate(forTesting: ())
        await PhotoImportPingDeduplicator.repairMissingHexVisitsOnce(
            modelContainer: container, defaultsSuiteName: suite, gate: gate)
        #expect(defaults.bool(forKey: PhotoImportPingDeduplicator.hexVisitRepairCompletedKey))
        let fresh = ModelContext(container)
        let rows = try fresh.fetch(FetchDescriptor<HexVisit>())
        #expect(rows.count == 2)
        let restored = try #require(rows.first { $0.h3Index == first.h3IndexRes6 })
        #expect(restored.firstVisited == t(10))
        #expect(restored.lastVisited == t(20))
        #expect(restored.visitCount == 1)
        let preserved = try #require(rows.first { $0.h3Index == existing.h3Index })
        #expect(preserved.firstVisited == t(1))
        #expect(preserved.lastVisited == t(100))
        #expect(preserved.visitCount == 99)
        let pings = try fresh.fetch(FetchDescriptor<LocationPing>())
        #expect(pings.count == 3)
        #expect(pings.filter { $0.isProcessed }.count == 2)
        #expect(defaults.object(forKey: PhotoImportPingDeduplicator.orphanPingFirstObservedKey) == nil)

        // A later missing cell proves completion skips even additive work.
        let later = makePing(at: t(40), lat: 48.8597, lon: 2.4216)
        later.h3IndexRes6 = try #require(H3Service.cellIndex(latitude: later.latitude, longitude: later.longitude))
        context.insert(later)
        try context.save()
        await PhotoImportPingDeduplicator.repairMissingHexVisitsOnce(
            modelContainer: container, defaultsSuiteName: suite, gate: gate)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<HexVisit>()) == 2)
    }

    @Test("launch repair skips CloudKit-configured stores without setting completion")
    func launchRepairSkipsCloudStore() async throws {
        let container = try repairContainer(cloud: true)
        #expect(container.configurations.contains { $0.cloudKitContainerIdentifier != nil })
        let suite = "hex-repair-cloud-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = ModelContext(container)
        context.insert(makePing(at: t(10)))
        try context.save()
        await PhotoImportPingDeduplicator.repairMissingHexVisitsOnce(
            modelContainer: container, defaultsSuiteName: suite, gate: PipelineGate(forTesting: ()))
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<HexVisit>()) == 0)
        #expect(!defaults.bool(forKey: PhotoImportPingDeduplicator.hexVisitRepairCompletedKey))
    }

    @Test("failed or cancelled launch repair does not mark completion and retries", arguments: [false, true])
    func launchRepairRetries(cancelled: Bool) async throws {
        let container = try repairContainer()
        let suite = "hex-repair-retry-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = ModelContext(container)
        let ping = makePing(at: t(10))
        ping.h3IndexRes6 = try #require(H3Service.cellIndex(latitude: Self.baseLat, longitude: Self.baseLon))
        context.insert(ping)
        try context.save()
        let gate = PipelineGate(forTesting: ())
        let operation = Task {
            if cancelled { withUnsafeCurrentTask { $0?.cancel() } }
            await PhotoImportPingDeduplicator.$failHexVisitRepairSaveForTesting.withValue(!cancelled) {
                await PhotoImportPingDeduplicator.repairMissingHexVisitsOnce(
                    modelContainer: container, defaultsSuiteName: suite, gate: gate)
            }
        }
        await operation.value
        #expect(!defaults.bool(forKey: PhotoImportPingDeduplicator.hexVisitRepairCompletedKey))
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<HexVisit>()) == 0)
        await PhotoImportPingDeduplicator.repairMissingHexVisitsOnce(
            modelContainer: container, defaultsSuiteName: suite, gate: gate)
        #expect(defaults.bool(forKey: PhotoImportPingDeduplicator.hexVisitRepairCompletedKey))
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<HexVisit>()) == 1)
    }

    @Test("launch repair restores every missing cell in one pass with complete date envelopes")
    func launchRepairRestoresAllCellsInOnePass() async throws {
        let container = try repairContainer()
        let suite = "hex-repair-batch-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = ModelContext(container)
        for latitude in [37.9838, 40.6401] {
            for time in [10.0, 20.0, 30.0] {
                let ping = makePing(at: t(time), lat: latitude)
                ping.h3IndexRes6 = try #require(H3Service.cellIndex(latitude: latitude, longitude: Self.baseLon))
                context.insert(ping)
            }
        }
        // A live ping is not import evidence and must not seed a row.
        let live = makePing(at: t(40), lat: 48.8597, lon: 2.4216)
        live.source = .liveSLC
        live.h3IndexRes6 = try #require(H3Service.cellIndex(latitude: live.latitude, longitude: live.longitude))
        context.insert(live)
        try context.save()
        await PhotoImportPingDeduplicator.repairMissingHexVisitsOnce(
            modelContainer: container, defaultsSuiteName: suite, gate: PipelineGate(forTesting: ()))
        #expect(defaults.bool(forKey: PhotoImportPingDeduplicator.hexVisitRepairCompletedKey))
        let rows = try ModelContext(container).fetch(FetchDescriptor<HexVisit>())
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.firstVisited == t(10) && $0.lastVisited == t(30) && $0.visitCount == 1 })
        #expect(!rows.contains { $0.h3Index == live.h3IndexRes6 })
    }

    @Test("empty store → no-op, store stays empty (count >= 2 guard)")
    func emptyStoreIsNoOp() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        await PhotoImportPingDeduplicator.deduplicateAll(modelContainer: container, bypassSingleFlightForTesting: true)
        #expect(try fetchAll(container).isEmpty)
    }

    @Test("single import ping → untouched (count >= 2 guard skips the pass)")
    func singleImportPingSurvives() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let only = makePing(at: t(1_000))
        ctx.insert(only)
        let id = only.id
        try ctx.save()

        await PhotoImportPingDeduplicator.deduplicateAll(modelContainer: container, bypassSingleFlightForTesting: true)

        let rows = try fetchImports(container)
        #expect(rows.count == 1)
        #expect(rows.first?.id == id)
    }

    // MARK: - Core duplicate collapse (within 90 s & ≤200 m)

    @Test("two import pings same spot within 90 s → later-by-sort deleted, earlier survives")
    func twoSameSpotWithinWindowCollapse() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // 30 s apart, identical coords → other (later timestamp) deleted.
        let early = makePing(at: t(1_000))
        let late = makePing(at: t(1_030))
        ctx.insert(early)
        ctx.insert(late)
        let earlyID = early.id
        try ctx.save()

        await PhotoImportPingDeduplicator.deduplicateAll(modelContainer: container, bypassSingleFlightForTesting: true)

        let rows = try fetchImports(container)
        #expect(rows.count == 1)
        #expect(rows.first?.id == earlyID)
    }

    @Test("timeline/GPX duplicates dedup cross-device too; live SLC stays excluded")
    func externalImportSourcesDedup() async throws {
        // Pre-fix, the predicate was hard-coded to photoImport: the same
        // Google Timeline file imported on two devices duplicated every
        // ping PERMANENTLY (no deduplicator, no cross-device gate).
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        // Same-file two-device Timeline import: identical timestamp+coords.
        let timelineA = makePing(at: t(1_000), source: .timelineImport)
        let timelineB = makePing(at: t(1_000), source: .timelineImport)
        // GPX pair; a GENUINE duplicate (same instant), which is what a
        // two-device import of the same file produces. A 30 s-apart pair is
        // not a duplicate for a recorded track and is pinned separately below.
        // The recorded-track control must retain both points.
        let gpxA = makePing(at: t(10_000), source: .gpxImport)
        let gpxB = makePing(at: t(10_000), source: .gpxImport)
        // Cross-domain pair (photo + timeline fix of the same moment): each
        // is removed by a different action, so both are kept.
        let photo = makePing(at: t(20_000), source: .photoImport)
        let timelineC = makePing(at: t(20_010), source: .timelineImport)
        // Live SLC noise inside a window; never considered.
        let live = makePing(at: t(1_010), source: .liveSLC)
        for ping in [timelineA, timelineB, gpxA, gpxB, photo, timelineC, live] {
            ctx.insert(ping)
        }
        let expectedSurvivors = Set([
            // Timestamp tie → smaller uuidString survives (convergence rule).
            min(timelineA.id.uuidString, timelineB.id.uuidString),
            min(gpxA.id.uuidString, gpxB.id.uuidString),
            photo.id.uuidString,
            timelineC.id.uuidString,
            live.id.uuidString,
        ])
        try ctx.save()

        await PhotoImportPingDeduplicator.deduplicateAll(modelContainer: container, bypassSingleFlightForTesting: true)

        let survivors = Set(try fetchAll(container).map(\.id.uuidString))
        #expect(survivors == expectedSurvivors)
    }

    /// A recorded GPX track is already thinned to >= 60 s by the parser, so
    /// applying the synthesized 90 s / 200 m rule to it re-thinned it to 120 s
    /// and silently discarded alternate points of every walking or running
    /// track. This is the post-hoc check:
    /// it runs on every launch and every CloudKit push, so without it the
    /// insert-time fix alone would be undone hours later.
    @Test("a 30 s-apart GPX pair is kept; a recorded track is not re-thinned")
    func gpxNeighboursWithinNinetySecondsSurvive() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let first = makePing(at: t(10_000), source: .gpxImport)
        let second = makePing(at: t(10_030), source: .gpxImport)
        // The same 30 s spacing from a SYNTHESIZED source is still a duplicate.
        let photoA = makePing(at: t(50_000), source: .photoImport)
        let photoB = makePing(at: t(50_030), source: .photoImport)
        for ping in [first, second, photoA, photoB] { ctx.insert(ping) }
        try ctx.save()

        await PhotoImportPingDeduplicator.deduplicateAll(modelContainer: container, bypassSingleFlightForTesting: true)

        let survivors = Set(try fetchAll(container).map(\.id.uuidString))
        #expect(survivors.contains(first.id.uuidString))
        #expect(survivors.contains(second.id.uuidString))
        // Keep-first is (timestamp, uuid): with DIFFERENT timestamps the
        // earlier ping is the candidate and survives; uuid only breaks ties.
        #expect(survivors.contains(photoA.id.uuidString))
        #expect(!survivors.contains(photoB.id.uuidString))
    }

    @Test("a rejected GPX time pair does not skip later eligible mixed-source comparisons")
    func delayedLocationAfterRejectedTimePair() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let photo = makePing(at: t(1_000))
        let gpx = makePing(at: t(1_016), source: .gpxImport)
        let timeline = makePing(at: t(1_030), source: .timelineImport)
        let secondPhoto = makePing(at: t(1_090))
        let gpxBoundary = makePing(at: t(1_031), source: .gpxImport)
        for ping in [secondPhoto, gpxBoundary, timeline, gpx, photo] { context.insert(ping) }
        let expected = Set([photo.id, gpx.id])
        try context.save()
        await PhotoImportPingDeduplicator.deduplicateAll(
            modelContainer: container, bypassSingleFlightForTesting: true)
        #expect(Set(try fetchAll(container).map(\.id)) == expected)
    }

    @Test("exactly 90 s apart, same spot → still a duplicate (window is inclusive at the boundary)")
    func exactly90sIsStillDuplicate() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // delta == 90 fails the `> 90` break test, so the pair IS compared and
        // (same spot) deleted. Confirms the boundary belongs to the window.
        let early = makePing(at: t(2_000))
        let late = makePing(at: t(2_090))
        ctx.insert(early)
        ctx.insert(late)
        let earlyID = early.id
        try ctx.save()

        await PhotoImportPingDeduplicator.deduplicateAll(modelContainer: container, bypassSingleFlightForTesting: true)

        let rows = try fetchImports(container)
        #expect(rows.count == 1)
        #expect(rows.first?.id == earlyID)
    }

    @Test("just past 90 s (+91 s strict-greater) → NOT a duplicate, both survive")
    func justPast90sBothSurvive() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // delta == 91 > 90 → inner loop breaks before comparing → both kept.
        ctx.insert(makePing(at: t(3_000)))
        ctx.insert(makePing(at: t(3_091)))
        try ctx.save()

        await PhotoImportPingDeduplicator.deduplicateAll(modelContainer: container, bypassSingleFlightForTesting: true)

        #expect(try fetchImports(container).count == 2)
    }

    // MARK: - Spatial threshold (≤200 m deleted, >200 m survives)

    @Test(">200 m apart within the time window → both survive (spatial guard)")
    func farApartBothSurvive() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let farLon = lonOffsetEastMeters(500) // comfortably beyond 200 m
        let a = makePing(at: t(4_000))
        let b = makePing(at: t(4_010), lon: farLon)
        // Sanity: the realized geodesic distance really is >200 m.
        let d = CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
        #expect(d > 200)
        ctx.insert(a)
        ctx.insert(b)
        try ctx.save()

        await PhotoImportPingDeduplicator.deduplicateAll(modelContainer: container, bypassSingleFlightForTesting: true)

        #expect(try fetchImports(container).count == 2)
    }

    @Test("≤200 m apart within the time window → duplicate, later-by-sort deleted")
    func nearWithinThresholdCollapses() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let nearLon = lonOffsetEastMeters(120) // well inside 200 m
        let early = makePing(at: t(5_000))
        let late = makePing(at: t(5_010), lon: nearLon)
        // Sanity: realized distance is inside the threshold.
        let d = CLLocation(latitude: early.latitude, longitude: early.longitude)
            .distance(from: CLLocation(latitude: late.latitude, longitude: late.longitude))
        #expect(d <= 200)
        ctx.insert(early)
        ctx.insert(late)
        let earlyID = early.id
        try ctx.save()

        await PhotoImportPingDeduplicator.deduplicateAll(modelContainer: container, bypassSingleFlightForTesting: true)

        let rows = try fetchImports(container)
        #expect(rows.count == 1)
        #expect(rows.first?.id == earlyID)
    }

    // MARK: - Tiebreak on identical timestamp

    @Test("tie on timestamp, same spot → smaller id.uuidString survives, larger deleted")
    func tieOnTimestampSmallerUuidSurvives() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let same = t(6_000)
        let a = makePing(at: same)
        let b = makePing(at: same)
        ctx.insert(a)
        ctx.insert(b)
        // The sort places the smaller uuidString first; that one is `candidate`
        // and is KEPT, the other deleted.
        let expectedSurvivor = min(a.id.uuidString, b.id.uuidString)
        try ctx.save()

        await PhotoImportPingDeduplicator.deduplicateAll(modelContainer: container, bypassSingleFlightForTesting: true)

        let rows = try fetchImports(container)
        #expect(rows.count == 1)
        #expect(rows.first?.id.uuidString == expectedSurvivor)
    }

    // MARK: - Multi-ping groups

    @Test("three import pings same spot inside one window → collapse to one survivor (earliest)")
    func threeInOneWindowCollapseToOne() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let p1 = makePing(at: t(7_000))
        let p2 = makePing(at: t(7_020))
        let p3 = makePing(at: t(7_040))
        ctx.insert(p1); ctx.insert(p2); ctx.insert(p3)
        let firstID = p1.id
        try ctx.save()

        await PhotoImportPingDeduplicator.deduplicateAll(modelContainer: container, bypassSingleFlightForTesting: true)

        let rows = try fetchImports(container)
        #expect(rows.count == 1)
        #expect(rows.first?.id == firstID)
    }

    @Test("two independent duplicate pairs far apart in time → each collapses to its earliest")
    func twoIndependentPairsEachCollapse() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // Pair 1 around t=8_000 (same spot, 20 s apart).
        let g1a = makePing(at: t(8_000))
        let g1b = makePing(at: t(8_020))
        // Pair 2 around t=80_000 (far in time from pair 1, same spot, 20 s apart).
        let g2a = makePing(at: t(80_000))
        let g2b = makePing(at: t(80_020))
        ctx.insert(g1a); ctx.insert(g1b); ctx.insert(g2a); ctx.insert(g2b)
        let g1Survivor = g1a.id
        let g2Survivor = g2a.id
        try ctx.save()

        await PhotoImportPingDeduplicator.deduplicateAll(modelContainer: container, bypassSingleFlightForTesting: true)

        let rows = try fetchImports(container)
        #expect(rows.count == 2)
        let ids = Set(rows.map(\.id))
        #expect(ids.contains(g1Survivor))
        #expect(ids.contains(g2Survivor))
    }

    // MARK: - sourceRaw filter (live pings ignored)

    @Test("live SLC pings are never considered, while photoImport pings still dedup")
    func liveSlcPingsIgnored() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // Two live pings at the SAME spot/time as one another: if the filter
        // were broken they'd collapse; they must BOTH survive.
        ctx.insert(makePing(at: t(9_000), source: .liveSLC))
        ctx.insert(makePing(at: t(9_010), source: .liveSLC))
        // A separate import pair that DOES collapse, proving the pass ran.
        let impEarly = makePing(at: t(9_000))
        ctx.insert(impEarly)
        ctx.insert(makePing(at: t(9_010)))
        let impSurvivor = impEarly.id
        try ctx.save()

        await PhotoImportPingDeduplicator.deduplicateAll(modelContainer: container, bypassSingleFlightForTesting: true)

        // Both live pings untouched.
        let live = try fetchAll(container).filter { $0.sourceRaw == DataSource.liveSLC.rawValue }
        #expect(live.count == 2)
        // Import pair collapsed to the earlier one.
        let imports = try fetchImports(container)
        #expect(imports.count == 1)
        #expect(imports.first?.id == impSurvivor)
    }

    @Test("a single import ping among many live pings → guard counts only imports, nothing deleted")
    func singleImportAmongLivePingsUntouched() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // Many live pings (would satisfy a naive count>=2) but only ONE import.
        for i in 0..<5 {
            ctx.insert(makePing(at: t(Double(10_000 + i * 5)), source: .liveSLC))
        }
        let lone = makePing(at: t(10_100))
        ctx.insert(lone)
        let loneID = lone.id
        try ctx.save()

        await PhotoImportPingDeduplicator.deduplicateAll(modelContainer: container, bypassSingleFlightForTesting: true)

        // The lone import ping must survive; the import-only count is 1.
        let imports = try fetchImports(container)
        #expect(imports.count == 1)
        #expect(imports.first?.id == loneID)
        // Live pings all survive too (never considered).
        let live = try fetchAll(container).filter { $0.sourceRaw == DataSource.liveSLC.rawValue }
        #expect(live.count == 5)
    }

    // MARK: - Idempotence

    @Test("running Phase A twice is stable; survivor set unchanged on the 2nd pass")
    func idempotentRunningTwice() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let early = makePing(at: t(11_000))
        ctx.insert(early)
        ctx.insert(makePing(at: t(11_020)))
        ctx.insert(makePing(at: t(11_040)))
        let survivorID = early.id
        try ctx.save()

        await PhotoImportPingDeduplicator.deduplicateAll(modelContainer: container, bypassSingleFlightForTesting: true)
        let after1 = try fetchImports(container)
        #expect(after1.count == 1)
        #expect(after1.first?.id == survivorID)

        await PhotoImportPingDeduplicator.deduplicateAll(modelContainer: container, bypassSingleFlightForTesting: true)
        let after2 = try fetchImports(container)
        #expect(after2.count == 1)
        #expect(after2.first?.id == survivorID)
    }

    // MARK: - Order independence (shuffle, reused ids → same survivors)

    @Test("survivor set is independent of insertion order (shuffled inserts, reused ids)")
    func orderIndependentSurvivors() async throws {
        // Three import pings in one window at the same spot; whichever has the
        // smallest (timestamp,uuid) key survives regardless of insert order.
        let times = [t(12_000), t(12_020), t(12_040)]

        // Store A: ascending insert order.
        let containerA = try TestSupport.makeInMemoryContainer()
        let ctxA = ModelContext(containerA)
        let a0 = makePing(at: times[0])
        let a1 = makePing(at: times[1])
        let a2 = makePing(at: times[2])
        ctxA.insert(a0); ctxA.insert(a1); ctxA.insert(a2)
        try ctxA.save()
        await PhotoImportPingDeduplicator.deduplicateAll(modelContainer: containerA, bypassSingleFlightForTesting: true)
        let survivorsA = try fetchImports(containerA).map(\.id)

        // Store B: shuffled insert order, SAME id values reused so the
        // (timestamp, id) survivor selection is directly comparable.
        let containerB = try TestSupport.makeInMemoryContainer()
        let ctxB = ModelContext(containerB)
        let b2 = makePing(at: times[2]); b2.id = a2.id
        let b0 = makePing(at: times[0]); b0.id = a0.id
        let b1 = makePing(at: times[1]); b1.id = a1.id
        ctxB.insert(b2); ctxB.insert(b0); ctxB.insert(b1)
        try ctxB.save()
        await PhotoImportPingDeduplicator.deduplicateAll(modelContainer: containerB, bypassSingleFlightForTesting: true)
        let survivorsB = try fetchImports(containerB).map(\.id)

        #expect(survivorsA.count == 1)
        #expect(survivorsB.count == 1)
        #expect(Set(survivorsA) == Set(survivorsB))
        // And it is the earliest-by-timestamp ping (a0).
        #expect(survivorsA.first == a0.id)
    }

    /// Two devices restoring one backup each hold both rows, in opposite local
    /// order: a pass on either must delete neither, so their deletions can
    /// never add up to every copy. Repeat passes stay idempotent.
    @Test("equal-rank UUID twins both stay, with their stay membership", arguments: [false, true])
    func uuidTwinsPreserveMembership(reverseInsertion: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let first = makePing(at: t(15_000))
        let second = makePing(at: t(15_000))
        second.id = first.id
        let id = first.id
        for ping in reverseInsertion ? [second, first] : [first, second] {
            ctx.insert(ping)
        }
        let stay = Stay(
            startTime: t(15_000), endTime: t(16_000),
            centroidLatitude: Self.baseLat, centroidLongitude: Self.baseLon,
            h3IndexRes6: "861f8d4ffffffff", pingCount: 1,
            distanceFromHomeKm: 4, pingIDs: [id])
        ctx.insert(stay)
        try ctx.save()
        let physicalIDs = Set(try fetchImports(container).map(\.persistentModelID))
        #expect(physicalIDs.count == 2)

        for _ in 0..<2 {
            #expect(await PhotoImportPingDeduplicator.deduplicateAll(
                modelContainer: container, bypassSingleFlightForTesting: true))
            let rows = try fetchImports(container)
            #expect(Set(rows.map(\.persistentModelID)) == physicalIDs)
            #expect(rows.allSatisfy { $0.id == id })
            let stays = try ModelContext(container).fetch(FetchDescriptor<Stay>())
            #expect(stays.count == 1)
            #expect(stays.first?.pingIDs == [id])
            #expect(stays.first?.pingCount == 1)
        }
    }

    /// A strictly later copy of a UUID is still a duplicate every device
    /// ranks the same way: it goes, and its retained twin keeps the stay.
    /// An equal-rank twin of the keeper stays beside it.
    @Test("a strictly later UUID copy goes while equal-rank twins of the keeper stay")
    func strictlyRankedTwinIsDeleted() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // The keeper's UUID sorts first among the equal timestamps.
        let keeperID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let keeper = makePing(at: t(17_000)); keeper.id = keeperID
        let keeperTwin = makePing(at: t(17_000)); keeperTwin.id = keeperID
        let later = makePing(at: t(17_001)); later.id = keeperID
        let otherUUID = makePing(at: t(17_000))
        otherUUID.id = try #require(UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001"))
        for ping in [later, otherUUID, keeperTwin, keeper] { ctx.insert(ping) }
        let stay = Stay(
            startTime: t(17_000), endTime: t(17_100),
            centroidLatitude: Self.baseLat, centroidLongitude: Self.baseLon,
            h3IndexRes6: "861f8d4ffffffff", pingCount: 2,
            distanceFromHomeKm: 4, pingIDs: [keeper.id, otherUUID.id])
        ctx.insert(stay)
        try ctx.save()
        let kept = Set([keeper.persistentModelID, keeperTwin.persistentModelID])

        #expect(await PhotoImportPingDeduplicator.deduplicateAll(
            modelContainer: container, bypassSingleFlightForTesting: true))

        let rows = try fetchImports(container)
        #expect(Set(rows.map(\.persistentModelID)) == kept)
        let stays = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        #expect(stays.first?.pingIDs == [keeperID])
        #expect(stays.first?.pingCount == 1)
    }

    @Test("large dedup pass preserves UUID twins across retained-copy lookup chunks")
    func largeDuplicatePassPreservesTwinMembership() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let pairCount = 1_001
        var expectedIDs: [UUID] = []
        for index in 0..<pairCount {
            let id = try #require(UUID(uuidString: String(
                format: "00000000-0000-0000-0000-%012d", index + 1)))
            expectedIDs.append(id)
            // Separate groups beyond the dedup window to keep the scan small.
            // The later copy is a strictly ranked duplicate of its UUID.
            let time = t(50_000 + Double(index) * 180)
            let first = makePing(at: time)
            let second = makePing(at: time.addingTimeInterval(1))
            first.id = id
            second.id = id
            ctx.insert(first)
            ctx.insert(second)
        }
        let stay = Stay(
            startTime: t(50_000), endTime: t(50_000 + Double(pairCount) * 180),
            centroidLatitude: Self.baseLat, centroidLongitude: Self.baseLon,
            h3IndexRes6: "861f8d4ffffffff", pingCount: pairCount,
            distanceFromHomeKm: 4, pingIDs: expectedIDs)
        ctx.insert(stay)
        try ctx.save()
        #expect(try fetchImports(container).count == pairCount * 2)

        await PhotoImportPingDeduplicator.deduplicateAll(
            modelContainer: container, bypassSingleFlightForTesting: true)

        let rows = try fetchImports(container)
        #expect(rows.count == pairCount)
        #expect(Set(rows.map(\.id)) == Set(expectedIDs))
        let stays = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        #expect(stays.count == 1)
        #expect(stays.first?.pingIDs == expectedIDs)
        #expect(stays.first?.pingCount == pairCount)
    }

    // MARK: - Phase B title lifecycle

    @Test("closed Visit evidence preserves empty-ping stays and UUID twins; a failed backing read rolls back",
          arguments: [false, true])
    func closedVisitPreservesStay(readFails: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let kept = makePing(at: t(20_000))
        let duplicate = makePing(at: t(20_020))
        kept.isProcessed = true
        duplicate.isProcessed = true
        context.insert(kept)
        context.insert(duplicate)
        let trip = Trip(startDate: t(19_000))
        trip.isComplete = true
        trip.endDate = t(23_000)
        trip.aiGeneratedTitle = "Athens"
        context.insert(trip)
        let stay = Stay(
            startTime: t(19_000), endTime: t(23_000),
            centroidLatitude: Self.baseLat, centroidLongitude: Self.baseLon,
            h3IndexRes6: "861f8d4ffffffff", pingCount: 1,
            distanceFromHomeKm: 4, pingIDs: [duplicate.id])
        stay.category = .destination
        stay.locality = "Athens"
        context.insert(stay)
        stay.trip = trip
        let twin = Stay(
            startTime: stay.startTime, endTime: stay.endTime,
            centroidLatitude: Self.baseLat, centroidLongitude: Self.baseLon,
            h3IndexRes6: stay.h3IndexRes6, pingCount: 1,
            distanceFromHomeKm: 4, pingIDs: [duplicate.id])
        twin.id = stay.id
        context.insert(twin)
        let visit = Visit(arrivalDate: stay.startTime, departureDate: stay.endTime,
            latitude: Self.baseLat, longitude: Self.baseLon,
            horizontalAccuracy: 10, stayID: stay.id, isProcessed: true)
        context.insert(visit)
        try context.save()
        let stayID = stay.id
        let duplicateID = duplicate.id
        let tripID = trip.id

        let completed = await PhotoImportPingDeduplicator.$beforeVisitBackingReadForTesting.withValue({
            if readFails { throw CocoaError(.fileReadUnknown) }
        }) {
            await PhotoImportPingDeduplicator.deduplicateAll(
                modelContainer: container, bypassSingleFlightForTesting: true)
        }
        #expect(completed == !readFails)
        let fresh = ModelContext(container)
        let pings = try fresh.fetch(FetchDescriptor<LocationPing>())
        #expect(pings.count == (readFails ? 2 : 1))
        #expect(pings.contains { $0.id == duplicateID } == readFails)
        let stays = try fresh.fetch(FetchDescriptor<Stay>())
        #expect(stays.count == 2)
        #expect(stays.allSatisfy { $0.id == stayID })
        #expect(stays.allSatisfy { $0.pingIDs == (readFails ? [duplicateID] : []) })
        #expect(stays.allSatisfy { $0.pingCount == (readFails ? 1 : 0) })
        let savedTrip = try #require(try fresh.fetch(FetchDescriptor<Trip>()).first)
        #expect(savedTrip.id == tripID)
        #expect(savedTrip.startDate == t(19_000) && savedTrip.endDate == t(23_000))
        #expect(savedTrip.aiGeneratedTitle == "Athens")
        #expect(savedTrip.orderedStays.map(\.id) == [stayID])
        let savedVisit = try #require(try fresh.fetch(FetchDescriptor<Visit>()).first)
        #expect(savedVisit.stayID == stayID && savedVisit.isProcessed)
        #expect(savedVisit.departureDate == t(23_000))
        if readFails {
            #expect(try fresh.fetchCount(FetchDescriptor<HexVisit>()) == 0)
        }
    }

    @Test("Phase B keeps an emptied user-overridden stay and its trip")
    func phaseBKeepsEmptiedOverriddenStay() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let early = makePing(at: t(50_000))
        let duplicate = makePing(at: t(50_020))
        ctx.insert(early)
        ctx.insert(duplicate)
        let stay = Stay(
            startTime: t(50_000), endTime: t(51_000),
            centroidLatitude: Self.baseLat, centroidLongitude: Self.baseLon,
            h3IndexRes6: "861f8d4ffffffff", pingCount: 1,
            distanceFromHomeKm: 4, pingIDs: [duplicate.id])
        stay.category = .destination
        stay.userOverridden = true
        ctx.insert(stay)
        let trip = Trip(startDate: stay.startTime)
        trip.isComplete = true
        trip.endDate = stay.endTime
        ctx.insert(trip)
        stay.trip = trip
        stay.orderInTrip = 0
        let stayID = stay.id
        let tripID = trip.id
        try ctx.save()

        await PhotoImportPingDeduplicator.deduplicateAll(
            modelContainer: container, bypassSingleFlightForTesting: true)

        let fresh = ModelContext(container)
        #expect(try fetchImports(container).map(\.id) == [early.id])
        let saved = try #require(try fresh.fetch(FetchDescriptor<Stay>()).first)
        #expect(saved.id == stayID)
        #expect(saved.userOverridden)
        #expect(saved.pingIDs.isEmpty && saved.pingCount == 0)
        let savedTrip = try #require(try fresh.fetch(FetchDescriptor<Trip>()).first)
        #expect(savedTrip.id == tripID)
        #expect(savedTrip.orderedStays.map(\.id) == [stayID])
    }

    /// `owner`: 0 none, 1 custom name, 2 edited, 3 blank name only, 4 none
    /// on an open trip. A favourite or photo choice owns a trip without a
    /// name or edit, and may still sync in, so a completed trip with no
    /// counterpart to carry it to keeps its stay and duplicate ping; an open
    /// one is assembly's and goes.
    @Test("Phase B keeps every completed trip it would empty without a carry counterpart, whole, and empties an open one",
          arguments: [0, 1, 2, 3, 4])
    func phaseBKeepsUserOwnedEmptiedTrip(owner: Int) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let early = makePing(at: t(60_000))
        let duplicate = makePing(at: t(60_020))
        ctx.insert(early)
        ctx.insert(duplicate)
        let stay = Stay(
            startTime: t(60_000), endTime: t(61_000),
            centroidLatitude: Self.baseLat, centroidLongitude: Self.baseLon,
            h3IndexRes6: "861f8d4ffffffff", pingCount: 1,
            distanceFromHomeKm: 4, pingIDs: [duplicate.id])
        stay.category = .destination
        ctx.insert(stay)
        let trip = Trip(startDate: t(59_000))
        trip.isComplete = owner != 4
        trip.endDate = owner != 4 ? t(62_000) : nil
        trip.destinationSummary = "Athens"
        trip.countryCodes = "GR"
        switch owner {
        case 1: trip.customName = "Spring in Athens"
        case 2: trip.userEdited = true
        case 3: trip.customName = "  "
        default: break
        }
        ctx.insert(trip)
        stay.trip = trip
        stay.orderInTrip = 0
        let tripID = trip.id
        try ctx.save()

        await PhotoImportPingDeduplicator.deduplicateAll(
            modelContainer: container, bypassSingleFlightForTesting: true)

        let fresh = ModelContext(container)
        let remaining = try fresh.fetch(FetchDescriptor<Trip>())
        if owner != 4 {
            let saved = try #require(remaining.first)
            #expect(remaining.count == 1)
            #expect(saved.id == tripID)
            #expect(saved.orderedStays.map(\.pingIDs) == [[duplicate.id]])
            #expect(Set(try fetchImports(container).map(\.id)) == [early.id, duplicate.id])
            #expect(saved.startDate == t(59_000) && saved.endDate == t(62_000))
            #expect(saved.destinationSummary == "Athens" && saved.countryCodes == "GR")
        } else {
            #expect(try fresh.fetchCount(FetchDescriptor<Stay>()) == 0)
            #expect(try fetchImports(container).map(\.id) == [early.id])
            #expect(remaining.isEmpty)
        }
    }

    @Test("Phase B invalidates canonical and localized titles when a stay disappears")
    func phaseBStayDeletionInvalidatesTitles() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let early = makePing(at: t(20_000))
        let duplicate = makePing(at: t(20_020))
        ctx.insert(early)
        ctx.insert(duplicate)

        let keptStay = Stay(
            startTime: t(20_000), endTime: t(21_000),
            centroidLatitude: Self.baseLat, centroidLongitude: Self.baseLon,
            h3IndexRes6: "861f8d4ffffffff", pingCount: 1,
            distanceFromHomeKm: 4, pingIDs: [early.id])
        keptStay.category = .destination
        keptStay.locality = "Athens"
        let emptiedStay = Stay(
            startTime: t(22_000), endTime: t(23_000),
            centroidLatitude: Self.baseLat, centroidLongitude: Self.baseLon,
            h3IndexRes6: "861f8d4ffffffff", pingCount: 1,
            distanceFromHomeKm: 4, pingIDs: [duplicate.id])
        emptiedStay.category = .destination
        emptiedStay.locality = "Lixoúri"
        ctx.insert(keptStay)
        ctx.insert(emptiedStay)

        let trip = Trip(startDate: keptStay.startTime)
        trip.isComplete = true
        trip.endDate = emptiedStay.endTime
        trip.aiGeneratedTitle = "Athens & Lixoúri"
        ctx.insert(trip)
        keptStay.trip = trip
        keptStay.orderInTrip = 0
        emptiedStay.trip = trip
        emptiedStay.orderInTrip = 1
        ctx.insert(TripTitleVariant(
            languageTag: "de",
            title: "Athen & Lixoúri",
            sourceTitle: "Athens & Lixoúri",
            trip: trip))
        let tripID = trip.id
        try ctx.save()

        await PhotoImportPingDeduplicator.deduplicateAll(
            modelContainer: container,
            bypassSingleFlightForTesting: true)

        let fresh = ModelContext(container)
        let predicate = #Predicate<Trip> { $0.id == tripID }
        let saved = try #require(try fresh.fetch(
            FetchDescriptor<Trip>(predicate: predicate)).first)
        #expect(saved.orderedStays.map(\.id) == [keptStay.id])
        #expect(saved.aiGeneratedTitle == "Athens")
        #expect((saved.localizedTitles ?? []).isEmpty)
    }

    @Test("Phase B preserves titles when only duplicate ping membership changes")
    func phaseBPingCountOnlyPreservesTitles() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let early = makePing(at: t(30_000))
        let duplicate = makePing(at: t(30_020))
        ctx.insert(early)
        ctx.insert(duplicate)

        let stay = Stay(
            startTime: t(30_000), endTime: t(31_000),
            centroidLatitude: Self.baseLat, centroidLongitude: Self.baseLon,
            h3IndexRes6: "861f8d4ffffffff", pingCount: 2,
            distanceFromHomeKm: 4, pingIDs: [early.id, duplicate.id])
        stay.category = .destination
        stay.locality = "Athens"
        ctx.insert(stay)
        let trip = Trip(startDate: stay.startTime)
        trip.aiGeneratedTitle = "Athens"
        ctx.insert(trip)
        stay.trip = trip
        stay.orderInTrip = 0
        ctx.insert(TripTitleVariant(
            languageTag: "de",
            title: "Athen",
            sourceTitle: "Athens",
            trip: trip))
        let tripID = trip.id
        try ctx.save()

        await PhotoImportPingDeduplicator.deduplicateAll(
            modelContainer: container,
            bypassSingleFlightForTesting: true)

        let fresh = ModelContext(container)
        let predicate = #Predicate<Trip> { $0.id == tripID }
        let saved = try #require(try fresh.fetch(
            FetchDescriptor<Trip>(predicate: predicate)).first)
        #expect(saved.aiGeneratedTitle == "Athens")
        #expect(saved.localizedTitles?.first?.title == "Athen")
        #expect(saved.orderedStays.first?.pingCount == 1)
    }

    @Test("Phase B invalidates titles when it repairs stale trip boundaries")
    func phaseBBoundaryRepairInvalidatesTitles() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let early = makePing(at: t(40_000))
        let duplicate = makePing(at: t(40_020))
        ctx.insert(early)
        ctx.insert(duplicate)

        let stay = Stay(
            startTime: t(40_000), endTime: t(41_000),
            centroidLatitude: Self.baseLat, centroidLongitude: Self.baseLon,
            h3IndexRes6: "861f8d4ffffffff", pingCount: 2,
            distanceFromHomeKm: 4, pingIDs: [early.id, duplicate.id])
        stay.category = .destination
        stay.locality = "Athens"
        ctx.insert(stay)
        let trip = Trip(startDate: t(39_000))
        trip.isComplete = true
        trip.endDate = t(42_000)
        trip.aiGeneratedTitle = "Athens Weekend"
        ctx.insert(trip)
        stay.trip = trip
        stay.orderInTrip = 0
        ctx.insert(TripTitleVariant(
            languageTag: "de",
            title: "Athen-Wochenende",
            sourceTitle: "Athens Weekend",
            trip: trip))
        let tripID = trip.id
        try ctx.save()

        await PhotoImportPingDeduplicator.deduplicateAll(
            modelContainer: container,
            bypassSingleFlightForTesting: true)

        let fresh = ModelContext(container)
        let predicate = #Predicate<Trip> { $0.id == tripID }
        let saved = try #require(try fresh.fetch(
            FetchDescriptor<Trip>(predicate: predicate)).first)
        #expect(saved.startDate == stay.startTime)
        #expect(saved.endDate == stay.endTime)
        #expect(saved.aiGeneratedTitle == "Athens")
        #expect((saved.localizedTitles ?? []).isEmpty)
    }

    // MARK: - Orphan sweep inside the pass, completion report

    @Test("an idle pass re-adopts an aged orphan and deletes a duplicate in the same pass")
    func idlePassReadoptsAgedOrphanAndDeletesDuplicateInOnePass() async throws {
        let key = PhotoImportPingDeduplicator.orphanPingFirstObservedKey
        let suite = "ping-dedup-idle-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let kept = makePing(at: t(70_000))
        let duplicate = makePing(at: t(70_030))
        let orphan = makePing(at: t(900_000), lat: 48.8597, lon: 2.4216)
        for ping in [kept, duplicate, orphan] {
            ping.isProcessed = true
            ctx.insert(ping)
        }
        let stay = Stay(
            startTime: t(70_000), endTime: t(71_000),
            centroidLatitude: Self.baseLat, centroidLongitude: Self.baseLon,
            h3IndexRes6: "861f8d4ffffffff", pingCount: 2,
            distanceFromHomeKm: 4, pingIDs: [kept.id, duplicate.id])
        ctx.insert(stay)
        try ctx.save()
        let keptID = kept.id
        let duplicateID = duplicate.id
        let orphanID = orphan.id
        defaults.set(
            [orphanID.uuidString: Date.now.timeIntervalSince1970
                - 2 * PhotoImportPingDeduplicator.orphanPingGracePeriod],
            forKey: key)

        let completed = await PhotoImportPingDeduplicator.deduplicateAll(
            modelContainer: container, bypassSingleFlightForTesting: true,
            defaults: defaults)

        #expect(completed)
        let rows = try fetchAll(container)
        #expect(!rows.contains { $0.id == duplicateID })
        let readopted = try #require(rows.first { $0.id == orphanID })
        #expect(readopted.isProcessed == false)
        let stays = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        #expect(stays.first?.pingIDs == [keptID])
        #expect(stays.first?.pingCount == 1)
        let observed = defaults.dictionary(forKey: key) ?? [:]
        #expect(observed[orphanID.uuidString] == nil)
    }

    @Test("a deferred pass reports incomplete; the idle pass reports completion")
    func deferredPingDedupReportsIncomplete() async throws {
        let suite = "ping-dedup-deferred-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        ctx.insert(makePing(at: t(80_000)))
        ctx.insert(makePing(at: t(80_030)))
        try ctx.save()

        let deferred = await PhotoImportPingDeduplicator.deduplicateAll(
            modelContainer: container, bypassSingleFlightForTesting: true,
            importActivityForTesting: (photo: true, external: false),
            defaults: defaults)
        #expect(!deferred)
        #expect(try fetchImports(container).count == 2)

        let idle = await PhotoImportPingDeduplicator.deduplicateAll(
            modelContainer: container, bypassSingleFlightForTesting: true,
            importActivityForTesting: (photo: false, external: false),
            defaults: defaults)
        #expect(idle)
        #expect(try fetchImports(container).count == 1)
    }

    @Test("processed import pings with no stays report the mid-sync sweep as incomplete")
    func readoptionMidSyncReportsIncomplete() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        for time in [t(90_000), t(95_000)] {
            let ping = makePing(at: time)
            ping.isProcessed = true
            ctx.insert(ping)
        }
        try ctx.save()

        let completed = await PhotoImportPingDeduplicator.deduplicateAll(
            modelContainer: container, bypassSingleFlightForTesting: true)

        #expect(!completed)
        #expect(try fetchAll(container).allSatisfy { $0.isProcessed })
    }

    // MARK: - Parity with the model-reading scan

    /// The keep-first scan as it ran before the pass read each ping's fields
    /// once: every comparison reads the models. The oracle for that rewrite.
    private func modelReadingDeletions(_ pings: [LocationPing]) -> Set<PersistentIdentifier> {
        let sorted = pings.sorted { a, b in
            if a.timestamp != b.timestamp { return a.timestamp < b.timestamp }
            if a.id != b.id { return a.id.uuidString < b.id.uuidString }
            return a.persistentModelID < b.persistentModelID
        }
        var deleted: Set<PersistentIdentifier> = []
        for i in 0..<sorted.count {
            let candidate = sorted[i]
            guard !deleted.contains(candidate.persistentModelID) else { continue }
            var candidateLoc: CLLocation?
            let candidateWindow = ImportDedupPolicy.thresholds(for: candidate.source).windowSeconds
            var j = i + 1
            while j < sorted.count {
                let other = sorted[j]
                if other.timestamp.timeIntervalSince(candidate.timestamp) > candidateWindow { break }
                if deleted.contains(other.persistentModelID) { j += 1; continue }
                if other.timestamp == candidate.timestamp, other.id == candidate.id { j += 1; continue }
                if !ImportDedupPolicy.mayCollapse(candidate.source, other.source) { j += 1; continue }
                let pair = ImportDedupPolicy.pair(candidate.source, other.source)
                if other.timestamp.timeIntervalSince(candidate.timestamp) <= pair.windowSeconds {
                    let location = candidateLoc
                        ?? CLLocation(latitude: candidate.latitude, longitude: candidate.longitude)
                    candidateLoc = location
                    let otherLoc = CLLocation(latitude: other.latitude, longitude: other.longitude)
                    if location.distance(from: otherLoc) <= pair.radiusMeters {
                        deleted.insert(other.persistentModelID)
                    }
                }
                j += 1
            }
        }
        return deleted
    }

    private func insertTrip(from start: Double, to end: Double, in ctx: ModelContext) -> Trip {
        let trip = Trip(startDate: t(start))
        trip.isComplete = true
        trip.endDate = t(end)
        ctx.insert(trip)
        return trip
    }

    private func insertStay(
        at start: Double, pingIDs: [UUID], trip: Trip?, order: Int, in ctx: ModelContext
    ) -> Stay {
        let stay = Stay(
            startTime: t(start), endTime: t(start + 100),
            centroidLatitude: Self.baseLat, centroidLongitude: Self.baseLon,
            h3IndexRes6: "861f8d4ffffffff", pingCount: pingIDs.count,
            distanceFromHomeKm: 4, pingIDs: pingIDs)
        stay.category = .destination
        stay.locality = "Stay \(Int(start))"
        ctx.insert(stay)
        stay.trip = trip
        stay.orderInTrip = order
        return stay
    }

    /// Covers ties, UUID twins (row twins, later copies, a live copy outside
    /// the import predicate), mixed source windows and chains. `processed`
    /// picks which read Phase B reconciles from: the orphan sweep's (true) or
    /// its own (false). Untouched stay fields guard the membership-only read.
    @Test("the field-copy pass deletes and reconciles exactly what the model-reading scan did",
          arguments: [false, true])
    func fieldCopyPassMatchesModelReadingScan(processed: Bool) async throws {
        let suite = "ping-dedup-parity-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        var pings: [LocationPing] = []
        var stays: [Stay] = []
        var trips: [Trip] = []

        // Offsets straddle the GPX (15 s, 25 m) and synthesized (90 s, 200 m)
        // limits with exact-time ties; no pair lies within 15 m of a radius,
        // so CLLocation's centimetre jitter cannot flip a comparison.
        var rng = PingCorpusRNG(state: 0x2026_1009)
        let sources: [DataSource] = [.photoImport, .timelineImport, .gpxImport]
        let seconds: [Double] = [0, 0, 5, 14, 16, 30, 89, 90, 91, 150]
        let meters: [Double] = [0, 0, 10, 60, 150, 500]
        for cluster in 0..<10 {
            let base = 100_000 + Double(cluster) * 1_000
            var drawn: [LocationPing] = []
            for _ in 0..<8 {
                drawn.append(makePing(
                    at: t(base + seconds.randomElement(using: &rng)!),
                    lon: lonOffsetEastMeters(meters.randomElement(using: &rng)!),
                    source: sources.randomElement(using: &rng)!))
            }
            let twinOf = drawn[Int.random(in: 0..<8, using: &rng)]
            let twin = makePing(at: twinOf.timestamp, lat: twinOf.latitude,
                lon: twinOf.longitude, source: twinOf.source)
            twin.id = twinOf.id
            let laterOf = drawn[Int.random(in: 0..<8, using: &rng)]
            let later = makePing(at: laterOf.timestamp.addingTimeInterval(5), lat: laterOf.latitude,
                lon: laterOf.longitude, source: laterOf.source)
            later.id = laterOf.id
            let liveOf = drawn[Int.random(in: 0..<8, using: &rng)]
            let live = makePing(at: liveOf.timestamp, lat: 39.6628, lon: 20.8612, source: .liveSLC)
            live.id = liveOf.id
            pings += drawn + [twin, later, live]
            let trip = insertTrip(from: base - 500, to: base + 900, in: ctx)
            trips.append(trip)
            stays.append(insertStay(at: base - 300, pingIDs: drawn.prefix(4).map(\.id) + [UUID()],
                trip: trip, order: 0, in: ctx))
            stays.append(insertStay(at: base + 300, pingIDs: drawn.suffix(4).map(\.id),
                trip: trip, order: 1, in: ctx))
        }

        // Fixed cases the corpus may miss; keeper UUIDs sort first.
        func fixedID(_ high: String, _ n: Int) -> UUID {
            UUID(uuidString: "\(high)-0000-0000-0000-\(String(format: "%012d", n))")!
        }
        // An emptied stay leaves its completed trip to the ghost sweep, which
        // can carry it to the identical journey holding the keeper.
        let keeper = makePing(at: t(50_000)); keeper.id = fixedID("00000000", 1)
        let dropped = makePing(at: t(50_000)); dropped.id = fixedID("FFFFFFFF", 1)
        let emptiedTrip = insertTrip(from: 49_000, to: 51_000, in: ctx)
        let emptiedStay = insertStay(at: 50_000, pingIDs: [dropped.id], trip: emptiedTrip, order: 0, in: ctx)
        let carryTrip = insertTrip(from: 49_000, to: 51_000, in: ctx)
        let keeperStay = insertStay(at: 50_000, pingIDs: [keeper.id], trip: carryTrip, order: 0, in: ctx)
        for trip in [emptiedTrip, carryTrip] {
            trip.destinationSummary = "Mirto"
            trip.countryCodes = "IT"
        }
        // A partly reconciled stay repairs its trip's dates.
        let kept = makePing(at: t(60_000)); kept.id = fixedID("00000000", 2)
        let duplicate = makePing(at: t(60_030)); duplicate.id = fixedID("FFFFFFFF", 2)
        let repairedTrip = insertTrip(from: 59_000, to: 61_000, in: ctx)
        let emptiedLead = insertStay(at: 59_500, pingIDs: [duplicate.id], trip: repairedTrip, order: 0, in: ctx)
        let partialStay = insertStay(at: 60_000, pingIDs: [kept.id, duplicate.id],
            trip: repairedTrip, order: 1, in: ctx)
        // A live row keeps a deleted import row's UUID alive.
        let first = makePing(at: t(70_000)); first.id = fixedID("00000000", 3)
        let second = makePing(at: t(70_000)); second.id = fixedID("FFFFFFFF", 3)
        let liveTwin = makePing(at: t(70_000), source: .liveSLC); liveTwin.id = second.id
        let liveTwinStay = insertStay(at: 70_000, pingIDs: [first.id, second.id], trip: nil, order: 0, in: ctx)
        // Equal-rank row twins both stay, with the membership.
        let rowTwinID = fixedID("00000000", 4)
        let rowA = makePing(at: t(80_000)); rowA.id = rowTwinID
        let rowB = makePing(at: t(80_000)); rowB.id = rowTwinID
        let rowTwinStay = insertStay(at: 80_000, pingIDs: [rowTwinID], trip: nil, order: 0, in: ctx)
        pings += [keeper, dropped, kept, duplicate, first, second, liveTwin, rowA, rowB]
        trips += [emptiedTrip, carryTrip, repairedTrip]
        stays += [emptiedStay, keeperStay, emptiedLead, partialStay, liveTwinStay, rowTwinStay]
        for ping in pings {
            ping.isProcessed = processed
            ctx.insert(ping)
        }
        try ctx.save()

        let seededStays = stays.map { stay in
            (id: stay.id, pingIDs: stay.pingIDs, start: stay.startTime, end: stay.endTime,
             locality: stay.locality, tripID: stay.trip?.id, order: stay.orderInTrip ?? 0)
        }
        let seededTrips = trips.map { (id: $0.id, start: $0.startDate, end: $0.endDate) }
        let before = try ModelContext(container).fetch(FetchDescriptor<LocationPing>())
        let importSources: Set<String> = ["photoImport", "timelineImport", "gpxImport"]
        let expectedDeleted = modelReadingDeletions(before.filter { importSources.contains($0.sourceRaw) })
        let retainedIDs = Set(before.filter { !expectedDeleted.contains($0.persistentModelID) }.map(\.id))
        let removedIDs = Set(before.filter { expectedDeleted.contains($0.persistentModelID) }.map(\.id))
            .subtracting(retainedIDs)
        let expectedRows = Set(before.map(\.persistentModelID)).subtracting(expectedDeleted)
        // Values only past this point: rows the pass deletes must not be read.
        let (emptiedStayID, emptiedTripID, partialStayID) = (emptiedStay.id, emptiedTrip.id, partialStay.id)
        let (repairedTripID, liveTwinStayID, rowTwinStayID) = (repairedTrip.id, liveTwinStay.id, rowTwinStay.id)
        let (keptID, firstID, secondID) = (kept.id, first.id, second.id)

        let completed = await PhotoImportPingDeduplicator.deduplicateAll(
            modelContainer: container, bypassSingleFlightForTesting: true, defaults: defaults)

        #expect(completed)
        let fresh = ModelContext(container)
        let after = try fresh.fetch(FetchDescriptor<LocationPing>())
        #expect(Set(after.map(\.persistentModelID)) == expectedRows)

        let afterStays = Dictionary(uniqueKeysWithValues:
            try fresh.fetch(FetchDescriptor<Stay>()).map { ($0.id, $0) })
        var survivingStays = 0
        for seeded in seededStays {
            let surviving = seeded.pingIDs.filter { !removedIDs.contains($0) }
            guard !surviving.isEmpty else {
                #expect(afterStays[seeded.id] == nil)
                continue
            }
            survivingStays += 1
            let stay = try #require(afterStays[seeded.id])
            #expect(stay.pingIDs == surviving)
            #expect(stay.pingCount == surviving.count)
            #expect(stay.startTime == seeded.start)
            #expect(stay.endTime == seeded.end)
            #expect(stay.locality == seeded.locality)
            #expect(stay.categoryRaw == StayCategory.destination.rawValue)
            #expect(stay.trip?.id == seeded.tripID)
        }
        #expect(afterStays.count == survivingStays)

        let afterTrips = Dictionary(uniqueKeysWithValues:
            try fresh.fetch(FetchDescriptor<Trip>()).map { ($0.id, $0) })
        for seeded in seededTrips {
            let members = seededStays.filter { $0.tripID == seeded.id }.sorted { $0.order < $1.order }
            let touched = members.contains { $0.pingIDs.contains { removedIDs.contains($0) } }
            let remaining = members.filter { $0.pingIDs.contains { !removedIDs.contains($0) } }
            guard touched else {
                let trip = try #require(afterTrips[seeded.id])
                #expect(trip.startDate == seeded.start)
                #expect(trip.endDate == seeded.end)
                continue
            }
            guard let firstStay = remaining.first, let lastStay = remaining.last else {
                // An emptied completed trip waits for the ghost sweep as it was.
                let trip = try #require(afterTrips[seeded.id])
                #expect((trip.stays ?? []).isEmpty)
                #expect(trip.startDate == seeded.start)
                #expect(trip.endDate == seeded.end)
                continue
            }
            let trip = try #require(afterTrips[seeded.id])
            #expect(trip.startDate == firstStay.start)
            #expect(trip.endDate == lastStay.end)
        }

        // The fixed cases took the paths they were built for.
        #expect(afterStays[emptiedStayID] == nil)
        #expect(afterTrips[emptiedTripID].map { ($0.stays ?? []).isEmpty } == true)
        #expect(afterStays[partialStayID]?.pingIDs == [keptID])
        #expect(afterTrips[repairedTripID]?.startDate == t(60_000))
        #expect(afterStays[liveTwinStayID]?.pingIDs == [firstID, secondID])
        #expect(after.filter { $0.id == secondID }.map(\.source) == [DataSource.liveSLC])
        #expect(afterStays[rowTwinStayID]?.pingIDs == [rowTwinID])
        #expect(after.filter { $0.id == rowTwinID }.count == 2)
    }

    @Test("duplicates beside an empty stay table: the duplicate goes, the sweep reports incomplete")
    func duplicatesWithEmptyStayTable() async throws {
        let suite = "ping-dedup-no-stays-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let early = makePing(at: t(110_000))
        let late = makePing(at: t(110_030))
        for ping in [early, late] {
            ping.isProcessed = true
            ctx.insert(ping)
        }
        let earlyID = early.id
        try ctx.save()

        let completed = await PhotoImportPingDeduplicator.deduplicateAll(
            modelContainer: container, bypassSingleFlightForTesting: true, defaults: defaults)

        #expect(!completed)
        let rows = try fetchImports(container)
        #expect(rows.map(\.id) == [earlyID])
        #expect(rows.allSatisfy { $0.isProcessed })
        #expect(defaults.object(forKey: PhotoImportPingDeduplicator.orphanPingFirstObservedKey) == nil)
    }

    @Test("stays without import pings: stale sightings are cleared and the stays are left alone")
    func noImportPingsLeavesStaysAlone() async throws {
        let key = PhotoImportPingDeduplicator.orphanPingFirstObservedKey
        let suite = "ping-dedup-no-imports-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let live = makePing(at: t(120_000), source: .liveSLC)
        live.isProcessed = true
        ctx.insert(live)
        let liveID = live.id
        _ = insertStay(at: 120_000, pingIDs: [liveID], trip: nil, order: 0, in: ctx)
        try ctx.save()
        defaults.set([UUID().uuidString: 0.0], forKey: key)

        let completed = await PhotoImportPingDeduplicator.deduplicateAll(
            modelContainer: container, bypassSingleFlightForTesting: true, defaults: defaults)

        #expect(completed)
        #expect(defaults.object(forKey: key) == nil)
        let fresh = ModelContext(container)
        #expect(try fresh.fetch(FetchDescriptor<Stay>()).map(\.pingIDs) == [[liveID]])
        #expect(try fresh.fetch(FetchDescriptor<LocationPing>()).map(\.id) == [liveID])
    }
}
