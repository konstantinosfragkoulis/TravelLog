//
//  PhotoAnnotationDeduplicatorTests.swift
//  TravelLogTests
//
//  CloudKit-convergence deduplicator for HiddenPhoto / PinnedPhoto. Pins the
//  dedup key (tripID | (cloudIdentifier ?? localIdentifier); cloud id wins so
//  the same iCloud photo collides cross-device, but per-trip so the same photo
//  in two trips is kept separately), the keep-oldest-by-(timestamp, id.uuidString)
//  survivor rule (retaining exact-rank physical twins), hidden/pinned independence, order-independence + run-twice
//  idempotence, and the orphan sweep (delete rows whose Trip is gone, but only
//  past the grace period that guards CloudKit out-of-order Trip arrival).
//  Live multi-device sync is out of scope.
//
//  `@MainActor` because the app target compiles with MainActor-by-default
//  isolation, which makes `@Model` types (HiddenPhoto, PinnedPhoto, Trip)
//  MainActor-isolated.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct PhotoAnnotationDeduplicatorTests {

    // MARK: - Fixtures

    static let tripA = UUID()
    static let tripB = UUID()

    private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    /// Build a HiddenPhoto. The init sets hiddenAt=.now; override cloudIdentifier
    /// and hiddenAt by assignment.
    private func makeHidden(trip: UUID, local: String, cloud: String? = nil, hiddenAt: Date) -> HiddenPhoto {
        let h = HiddenPhoto(localIdentifier: local, tripID: trip)
        h.cloudIdentifier = cloud
        h.hiddenAt = hiddenAt
        return h
    }

    private func makePinned(trip: UUID, local: String, cloud: String? = nil, pinnedAt: Date) -> PinnedPhoto {
        let p = PinnedPhoto(localIdentifier: local, tripID: trip)
        p.cloudIdentifier = cloud
        p.pinnedAt = pinnedAt
        return p
    }

    private func fetchHidden(_ container: ModelContainer) throws -> [HiddenPhoto] {
        try ModelContext(container).fetch(FetchDescriptor<HiddenPhoto>())
    }

    private func fetchPinned(_ container: ModelContainer) throws -> [PinnedPhoto] {
        try ModelContext(container).fetch(FetchDescriptor<PinnedPhoto>())
    }

    private func queueDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoAnnotationQueue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func archivedTrip(_ id: UUID, split: Bool = true) -> DissolvedTripRecord {
        DissolvedTripRecord(
            id: id, dissolvedAt: Self.orphanBase, displayName: "Archived trip",
            startDate: Self.orphanBase, endDate: Self.orphanBase, isComplete: true,
            destinationSummary: "", countryCodes: "", classifiedByAI: false,
            aiGeneratedTitle: nil, aiGeneratedSummary: nil, summarySourceRaw: nil,
            sourceRaw: DataSource.liveSLC.rawValue, customName: nil, userEdited: true,
            stays: [], photoAnnotations: [], splitByTemporaryHomeID: split ? UUID() : nil)
    }

    // MARK: - deduplicateAll: no-op / guards

    @Test("empty store → deduplicateAll is a no-op")
    func emptyStoreIsNoOp() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        await PhotoAnnotationDeduplicator.deduplicateAll(modelContainer: container)
        #expect(try fetchHidden(container).isEmpty)
        #expect(try fetchPinned(container).isEmpty)
    }

    @Test("one hidden + one pinned → both survive (count>1 guard returns 0 each)")
    func singleHiddenAndSinglePinnedUntouched() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        ctx.insert(makeHidden(trip: Self.tripA, local: "h1", hiddenAt: utc(2026, 1, 1)))
        ctx.insert(makePinned(trip: Self.tripA, local: "p1", pinnedAt: utc(2026, 1, 1)))
        try ctx.save()

        await PhotoAnnotationDeduplicator.deduplicateAll(modelContainer: container)

        #expect(try fetchHidden(container).count == 1)
        #expect(try fetchPinned(container).count == 1)
    }

    // MARK: - deduplicateAll: hidden key behavior

    @Test("two hidden, same trip + same local (both cloud nil) → collapse to one")
    func duplicateHiddenSameTripSameLocalCollapses() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        ctx.insert(makeHidden(trip: Self.tripA, local: "photoX", hiddenAt: utc(2026, 1, 1)))
        ctx.insert(makeHidden(trip: Self.tripA, local: "photoX", hiddenAt: utc(2026, 1, 2)))
        try ctx.save()

        await PhotoAnnotationDeduplicator.deduplicateAll(modelContainer: container)

        #expect(try fetchHidden(container).count == 1)
    }

    @Test("two hidden, same trip + same cloud id, DIFFERENT local → collapse (cloud id wins as stableID)")
    func duplicateHiddenKeyedByCloudIdentifierWhenPresent() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        ctx.insert(makeHidden(trip: Self.tripA, local: "deviceA-id", cloud: "cloud-123", hiddenAt: utc(2026, 1, 1)))
        ctx.insert(makeHidden(trip: Self.tripA, local: "deviceB-id", cloud: "cloud-123", hiddenAt: utc(2026, 1, 2)))
        try ctx.save()

        await PhotoAnnotationDeduplicator.deduplicateAll(modelContainer: container)

        #expect(try fetchHidden(container).count == 1)
    }

    @Test("same local under two different trips → both survive (key includes tripID)")
    func hiddenDifferentTripsNotMerged() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        ctx.insert(makeHidden(trip: Self.tripA, local: "sharedPhoto", hiddenAt: utc(2026, 1, 1)))
        ctx.insert(makeHidden(trip: Self.tripB, local: "sharedPhoto", hiddenAt: utc(2026, 1, 2)))
        try ctx.save()

        await PhotoAnnotationDeduplicator.deduplicateAll(modelContainer: container)

        #expect(try fetchHidden(container).count == 2)
    }

    @Test("same trip, two different locals (cloud nil) → both survive (distinct keys)")
    func hiddenDifferentPhotosSameTripNotMerged() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        ctx.insert(makeHidden(trip: Self.tripA, local: "photo1", hiddenAt: utc(2026, 1, 1)))
        ctx.insert(makeHidden(trip: Self.tripA, local: "photo2", hiddenAt: utc(2026, 1, 2)))
        try ctx.save()

        await PhotoAnnotationDeduplicator.deduplicateAll(modelContainer: container)

        #expect(try fetchHidden(container).count == 2)
    }

    @Test("duplicate hidden pair → survivor is the EARLIEST hiddenAt (ascending, first key wins)")
    func hiddenKeepsOldestByHiddenAt() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let early = makeHidden(trip: Self.tripA, local: "photoY", hiddenAt: utc(2026, 1, 1))
        let late = makeHidden(trip: Self.tripA, local: "photoY", hiddenAt: utc(2026, 6, 1))
        ctx.insert(late)
        ctx.insert(early)
        let earlyID = early.id
        try ctx.save()

        await PhotoAnnotationDeduplicator.deduplicateAll(modelContainer: container)

        let rows = try fetchHidden(container)
        #expect(rows.count == 1)
        #expect(rows.first?.id == earlyID)
    }

    @Test("duplicate hidden pair, identical hiddenAt → survivor is the smallest id.uuidString")
    func hiddenTieBrokenBySmallerIdUuidString() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let same = utc(2026, 4, 4)
        let a = makeHidden(trip: Self.tripA, local: "photoZ", hiddenAt: same)
        let b = makeHidden(trip: Self.tripA, local: "photoZ", hiddenAt: same)
        ctx.insert(a)
        ctx.insert(b)
        let expectedSurvivor = min(a.id.uuidString, b.id.uuidString)
        try ctx.save()

        await PhotoAnnotationDeduplicator.deduplicateAll(modelContainer: container)

        let rows = try fetchHidden(container)
        #expect(rows.count == 1)
        #expect(rows.first?.id.uuidString == expectedSurvivor)
    }

    // MARK: - deduplicateAll: pinned

    @Test("two pinned, same trip + same local → collapse to one (dedupPinned mirrors hidden)")
    func duplicatePinnedCollapses() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        ctx.insert(makePinned(trip: Self.tripA, local: "pinX", pinnedAt: utc(2026, 1, 1)))
        ctx.insert(makePinned(trip: Self.tripA, local: "pinX", pinnedAt: utc(2026, 1, 2)))
        try ctx.save()

        await PhotoAnnotationDeduplicator.deduplicateAll(modelContainer: container)

        #expect(try fetchPinned(container).count == 1)
    }

    // MARK: - deduplicateAll: idempotence + order independence

    @Test("running deduplicateAll twice → hidden/pinned counts + ids unchanged on 2nd pass")
    func idempotentRunningTwiceStable() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        ctx.insert(makeHidden(trip: Self.tripA, local: "h", hiddenAt: utc(2026, 1, 1)))
        ctx.insert(makeHidden(trip: Self.tripA, local: "h", hiddenAt: utc(2026, 1, 2)))
        ctx.insert(makePinned(trip: Self.tripA, local: "p", pinnedAt: utc(2026, 1, 1)))
        ctx.insert(makePinned(trip: Self.tripA, local: "p", pinnedAt: utc(2026, 1, 2)))
        try ctx.save()

        await PhotoAnnotationDeduplicator.deduplicateAll(modelContainer: container)
        let hidden1 = try fetchHidden(container)
        let pinned1 = try fetchPinned(container)
        #expect(hidden1.count == 1)
        #expect(pinned1.count == 1)
        let hiddenID1 = try #require(hidden1.first).id
        let pinnedID1 = try #require(pinned1.first).id

        await PhotoAnnotationDeduplicator.deduplicateAll(modelContainer: container)
        let hidden2 = try fetchHidden(container)
        let pinned2 = try fetchPinned(container)
        #expect(hidden2.count == 1)
        #expect(pinned2.count == 1)
        #expect(hidden2.first?.id == hiddenID1)
        #expect(pinned2.first?.id == pinnedID1)
    }

    @Test("survivor id for a collapsed group is independent of insertion order")
    func orderIndependentSurvivor() async throws {
        let early = utc(2026, 1, 1)
        let late = utc(2026, 6, 1)

        // Store A: early inserted first.
        let containerA = try TestSupport.makeInMemoryContainer()
        let ctxA = ModelContext(containerA)
        let a1 = makeHidden(trip: Self.tripA, local: "ph", hiddenAt: early)
        let a2 = makeHidden(trip: Self.tripA, local: "ph", hiddenAt: late)
        ctxA.insert(a1); ctxA.insert(a2)
        try ctxA.save()
        await PhotoAnnotationDeduplicator.deduplicateAll(modelContainer: containerA)
        let sA = try #require(try fetchHidden(containerA).first)

        // Store B: late inserted first, same ids reused.
        let containerB = try TestSupport.makeInMemoryContainer()
        let ctxB = ModelContext(containerB)
        let b2 = makeHidden(trip: Self.tripA, local: "ph", hiddenAt: late); b2.id = a2.id
        let b1 = makeHidden(trip: Self.tripA, local: "ph", hiddenAt: early); b1.id = a1.id
        ctxB.insert(b2); ctxB.insert(b1)
        try ctxB.save()
        await PhotoAnnotationDeduplicator.deduplicateAll(modelContainer: containerB)
        let sB = try #require(try fetchHidden(containerB).first)

        #expect(sA.id == sB.id)
    }

    @Test("hidden and pinned keep every exact-rank winning physical twin, delete lower-ranked twins, and stay stable in either insertion order",
          arguments: [false, true])
    func exactRankPhysicalTwinsSurvive(reverseInsertion: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let higherID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let first = utc(2026, 1, 1)
        let later = utc(2026, 1, 2)
        // Local identifiers differ across replicas; the cloud identifier groups
        // them. Only the first two rows share the winning synced rank.
        let cases = [
            ("winning-a", id, first), ("winning-b", id, first),
            ("later-a", id, later), ("later-b", id, later),
            ("higher-id-a", higherID, first), ("higher-id-b", higherID, first)
        ]
        var hidden: [HiddenPhoto] = []
        var pinned: [PinnedPhoto] = []
        for (local, rowID, date) in cases {
            let h = makeHidden(trip: Self.tripA, local: local, cloud: "same-cloud-photo", hiddenAt: date)
            let p = makePinned(trip: Self.tripA, local: local, cloud: "same-cloud-photo", pinnedAt: date)
            h.id = rowID
            p.id = rowID
            hidden.append(h)
            pinned.append(p)
        }
        for h in reverseInsertion ? Array(hidden.reversed()) : hidden { ctx.insert(h) }
        for p in reverseInsertion ? Array(pinned.reversed()) : pinned { ctx.insert(p) }
        try ctx.save()
        let hiddenWinners = Set(hidden.prefix(2).map(\.persistentModelID))
        let pinnedWinners = Set(pinned.prefix(2).map(\.persistentModelID))
        #expect(hiddenWinners.count == 2 && pinnedWinners.count == 2)

        for _ in 0..<2 {
            #expect(await PhotoAnnotationDeduplicator.deduplicateAll(modelContainer: container))
            #expect(Set(try fetchHidden(container).map(\.persistentModelID)) == hiddenWinners)
            #expect(Set(try fetchPinned(container).map(\.persistentModelID)) == pinnedWinners)
        }
    }

    @Test("a shared annotation UUID does not change local fallback, cloud, empty-cloud, delimiter or trip-scoped grouping")
    func physicalTwinsRetainAnnotationKeyBoundaries() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let id = UUID()
        let fields: [(trip: UUID, local: String, cloud: String?)] = [
            (Self.tripA, "legacy-a", nil), (Self.tripA, "legacy-b", nil),
            (Self.tripA, "device-a", "cloud-a"), (Self.tripA, "device-a", "cloud-b"),
            (Self.tripA, "empty-fallback", ""), (Self.tripA, "empty-fallback", nil),
            (Self.tripA, "same-local", "with|delimiter"), (Self.tripB, "same-local", "with|delimiter")
        ]
        var hidden: [HiddenPhoto] = []
        var pinned: [PinnedPhoto] = []
        for (index, field) in fields.enumerated() {
            // Distinct timestamps ensure a broken logical key would delete a
            // row; a blanket same-UUID exemption cannot satisfy the prior test.
            let date = utc(2026, 1, 1).addingTimeInterval(TimeInterval(index))
            let h = makeHidden(trip: field.trip, local: field.local, cloud: field.cloud, hiddenAt: date)
            let p = makePinned(trip: field.trip, local: field.local, cloud: field.cloud, pinnedAt: date)
            h.id = id
            p.id = id
            ctx.insert(h)
            ctx.insert(p)
            hidden.append(h)
            pinned.append(p)
        }
        try ctx.save()
        let hiddenPhysical = Set(hidden.map(\.persistentModelID))
        let pinnedPhysical = Set(pinned.map(\.persistentModelID))

        #expect(await PhotoAnnotationDeduplicator.deduplicateAll(modelContainer: container))
        #expect(Set(try fetchHidden(container).map(\.persistentModelID)) == hiddenPhysical)
        #expect(Set(try fetchPinned(container).map(\.persistentModelID)) == pinnedPhysical)
    }

    // MARK: - removeOrphans (device-local first-observed grace)

    static let orphanBase = Date(timeIntervalSince1970: 1_700_000_000)
    /// > orphanGracePeriod (24h) past `orphanBase`.
    static var pastGrace: Date { orphanBase.addingTimeInterval(25 * 3600) }

    /// A throwaway, isolated defaults domain so the first-observed map never
    /// touches `UserDefaults.standard` or leaks across tests.
    private func freshDefaults() -> UserDefaults {
        let name = "PhotoAnnotationDeduplicatorTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test("genuine orphan is kept on first sweep (first-observed) and deleted only past grace on a later sweep")
    func orphanDeletedOnlyAfterLocalGraceAcrossTwoPasses() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let defaults = freshDefaults()
        let ctx = ModelContext(container)
        // Non-empty Trip set so the mid-sync guard doesn't short-circuit.
        ctx.insert(Trip(startDate: utc(2026, 1, 1)))
        // Orphan whose user-action timestamp is ancient; must NOT drive deletion.
        ctx.insert(makeHidden(trip: UUID(), local: "orphan", hiddenAt: Self.orphanBase.addingTimeInterval(-90 * 86400)))
        ctx.insert(makePinned(trip: UUID(), local: "orphanPin", pinnedAt: Self.orphanBase.addingTimeInterval(-90 * 86400)))
        try ctx.save()

        // Pass 1: first observation → recorded, kept.
        await PhotoAnnotationDeduplicator.removeOrphans(modelContainer: container, now: Self.orphanBase, defaults: defaults)
        #expect(try fetchHidden(container).count == 1)
        #expect(try fetchPinned(container).count == 1)

        // Pass 2, 25h later: now past the local grace → deleted.
        await PhotoAnnotationDeduplicator.removeOrphans(modelContainer: container, now: Self.pastGrace, defaults: defaults)
        #expect(try fetchHidden(container).isEmpty)
        #expect(try fetchPinned(container).isEmpty)
    }

    @Test("historical rows survive initial sync until their Trip arrives, even past grace")
    func historicalOrphansSurviveUntilTripArrives() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let defaults = freshDefaults()
        let ctx = ModelContext(container)

        // The rows' parent Trip exists as an object (so we know its id) but is
        // NOT yet in the store; it hasn't finished the initial CloudKit import.
        let lateTrip = Trip(startDate: utc(2026, 1, 1))
        let lateTripID = lateTrip.id
        // A different, already-synced Trip so knownTripIDs is non-empty.
        ctx.insert(Trip(startDate: utc(2026, 2, 1)))
        // Historical hide/pin rows carrying months-old user-action timestamps.
        ctx.insert(makeHidden(trip: lateTripID, local: "h", hiddenAt: Self.orphanBase.addingTimeInterval(-120 * 86400)))
        ctx.insert(makePinned(trip: lateTripID, local: "p", pinnedAt: Self.orphanBase.addingTimeInterval(-120 * 86400)))
        try ctx.save()

        // Pass 1 right after restore: rows first-observed as orphans, kept.
        await PhotoAnnotationDeduplicator.removeOrphans(modelContainer: container, now: Self.orphanBase, defaults: defaults)
        #expect(try fetchHidden(container).count == 1)
        #expect(try fetchPinned(container).count == 1)

        // The parent Trip finishes syncing in.
        let ctx2 = ModelContext(container)
        ctx2.insert(lateTrip)
        try ctx2.save()

        // Pass 2, well past grace: rows are no longer orphans → kept, and the
        // first-observed entries are pruned from the map.
        await PhotoAnnotationDeduplicator.removeOrphans(modelContainer: container, now: Self.pastGrace, defaults: defaults)
        #expect(try fetchHidden(container).count == 1)
        #expect(try fetchPinned(container).count == 1)
        #expect(defaults.dictionary(forKey: "orphanFirstObserved_v1") == nil)
    }

    @Test("zero Trips but annotation rows present; mid-sync guard skips (nothing deleted, even past grace)")
    func emptyTripSetWithRowsIsTreatedAsMidSync() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let defaults = freshDefaults()
        let ctx = ModelContext(container)
        // No Trips at all, but hide/pin rows exist (fresh restore mid-import).
        ctx.insert(makeHidden(trip: UUID(), local: "h", hiddenAt: Self.orphanBase))
        ctx.insert(makePinned(trip: UUID(), local: "p", pinnedAt: Self.orphanBase))
        try ctx.save()

        // Even at a time long past grace, the empty-Trip guard prevents deletion.
        await PhotoAnnotationDeduplicator.removeOrphans(modelContainer: container, now: Self.pastGrace, defaults: defaults)
        #expect(try fetchHidden(container).count == 1)
        #expect(try fetchPinned(container).count == 1)
    }

    @Test("row whose tripID matches an existing Trip is never deleted")
    func removeOrphansKeepsRowWithExistingTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let defaults = freshDefaults()
        let ctx = ModelContext(container)
        let trip = Trip(startDate: utc(2026, 1, 1))
        ctx.insert(trip)
        let tripID = trip.id
        ctx.insert(makeHidden(trip: tripID, local: "kept", hiddenAt: Self.orphanBase.addingTimeInterval(-7200)))
        try ctx.save()

        await PhotoAnnotationDeduplicator.removeOrphans(modelContainer: container, now: Self.pastGrace, defaults: defaults)

        let rows = try fetchHidden(container)
        #expect(rows.count == 1)
        #expect(rows.first?.tripID == tripID)
    }

    @Test("map pruning: an orphan observed, then its Trip arrives ⇒ first-observed entry is cleared and the row survives")
    func mapPrunedWhenTripArrives() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let defaults = freshDefaults()
        let ctx = ModelContext(container)
        let trip = Trip(startDate: utc(2026, 3, 1))
        let tripID = trip.id
        ctx.insert(Trip(startDate: utc(2026, 1, 1))) // keep knownTripIDs non-empty
        ctx.insert(makeHidden(trip: tripID, local: "h", hiddenAt: Self.orphanBase))
        try ctx.save()

        await PhotoAnnotationDeduplicator.removeOrphans(modelContainer: container, now: Self.orphanBase, defaults: defaults)
        // Recorded as a first-observed orphan.
        #expect((defaults.dictionary(forKey: "orphanFirstObserved_v1") as? [String: Double])?.isEmpty == false)

        let ctx2 = ModelContext(container)
        ctx2.insert(trip)
        try ctx2.save()

        await PhotoAnnotationDeduplicator.removeOrphans(modelContainer: container, now: Self.pastGrace, defaults: defaults)
        #expect(try fetchHidden(container).count == 1)
        #expect(defaults.dictionary(forKey: "orphanFirstObserved_v1") == nil)
    }

    @Test("With iCloud on, orphans are deleted only after a successful import completes past the grace")
    func orphansWaitForImportPastGraceWithSyncOn() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let defaults = freshDefaults()
        defaults.set(true, forKey: AppDelegate.iCloudSyncEnabledKey)
        let ctx = ModelContext(container)
        ctx.insert(Trip(startDate: utc(2026, 1, 1)))
        ctx.insert(makeHidden(trip: UUID(), local: "orphan", hiddenAt: Self.orphanBase))
        ctx.insert(makePinned(trip: UUID(), local: "orphanPin", pinnedAt: Self.orphanBase))
        try ctx.save()

        await PhotoAnnotationDeduplicator.removeOrphans(modelContainer: container, now: Self.orphanBase, defaults: defaults)
        await PhotoAnnotationDeduplicator.removeOrphans(modelContainer: container, now: Self.pastGrace, defaults: defaults)
        #expect(try fetchHidden(container).count == 1)
        #expect(try fetchPinned(container).count == 1)

        defaults.set(
            Self.orphanBase.addingTimeInterval(24 * 3600 + 60),
            forKey: AppDelegate.lastSuccessfulCloudImportAtKey)
        await PhotoAnnotationDeduplicator.removeOrphans(modelContainer: container, now: Self.pastGrace, defaults: defaults)
        #expect(try fetchHidden(container).isEmpty)
        #expect(try fetchPinned(container).isEmpty)
    }

    @Test("removeOrphans on an empty store deletes nothing and returns")
    func removeOrphansEmptyStoreNoOp() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        await PhotoAnnotationDeduplicator.removeOrphans(modelContainer: container, now: Self.pastGrace, defaults: freshDefaults())
        #expect(try fetchHidden(container).isEmpty)
        #expect(try fetchPinned(container).isEmpty)
    }

    // MARK: - removeOrphans: carried-ghost replay

    private func logCarries(_ pairs: [(ghost: UUID, winner: UUID)], in defaults: UserDefaults) {
        defaults.set(pairs.map { "\($0.ghost.uuidString) \($0.winner.uuidString)" },
                     forKey: TripDeduplicator.carriedFavouritesKey)
    }

    /// Inserts one Trip row with `id`.
    private func insertTrip(id: UUID, in container: ModelContainer) throws {
        let ctx = ModelContext(container)
        let trip = Trip(startDate: utc(2026, 1, 1))
        trip.id = id
        ctx.insert(trip)
        try ctx.save()
    }

    private func orphanMap(_ defaults: UserDefaults) -> [String: Double]? {
        defaults.dictionary(forKey: PhotoAnnotationDeduplicator.firstObservedOrphansKey) as? [String: Double]
    }

    @Test("prepared and committed split archives and ordinary rescue records retain new late hidden/pinned rows outside their snapshots")
    func queuedArchivesOwnLatePhotoChoices() async throws {
        for (split, committed) in [(true, nil), (true, false), (true, true), (false, nil)] as [(Bool, Bool?)] {
            let directory = try queueDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let defaults = freshDefaults()
            let container = try TestSupport.makeInMemoryContainer()
            let original = UUID()
            let live = UUID()
            try insertTrip(id: live, in: container)
            var record = archivedTrip(original, split: split)
            try DissolvedTripQueue.append([record], in: directory)
            record.splitCommitted = committed
            try DissolvedTripQueue.append([record], in: directory)
            // A stale carry log must not steal a pending archive's own choices.
            logCarries([(original, live)], in: defaults)
            let ctx = ModelContext(container)
            let h = makeHidden(trip: original, local: "new-late-hidden", hiddenAt: Self.orphanBase)
            let p = makePinned(trip: original, local: "new-late-pin", pinnedAt: Self.orphanBase)
            ctx.insert(h)
            ctx.insert(p)
            try ctx.save()
            let hiddenPhysical = h.persistentModelID
            let pinnedPhysical = p.persistentModelID

            for now in [Self.orphanBase, Self.pastGrace] {
                let outcome = await PhotoAnnotationDeduplicator.sweepOrphans(
                    modelContainer: container, now: now, defaults: defaults, queueDirectory: directory)
                #expect(outcome.completed && outcome.deleted == 0 && outcome.rekeyedOnto.isEmpty)
                let hidden = try #require(try fetchHidden(container).first)
                let pinned = try #require(try fetchPinned(container).first)
                #expect(hidden.persistentModelID == hiddenPhysical && hidden.tripID == original)
                #expect(pinned.persistentModelID == pinnedPhysical && pinned.tripID == original)
                #expect(orphanMap(defaults) == nil)
            }
            #expect(try DissolvedTripQueue.loadThrowing(from: directory).first?.photoAnnotations == [])
        }
    }

    @Test("an unreadable Removed Trips queue changes neither mature orphan rows, carry keys nor prior observations")
    func unreadableQueueStopsOrphanSweep() async throws {
        let directory = try queueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queueURL = try #require(DissolvedTripQueue.fileURL(in: directory))
        let corrupt = Data("invalid queue json".utf8)
        try corrupt.write(to: queueURL)
        let defaults = freshDefaults()
        let container = try TestSupport.makeInMemoryContainer()
        let live = UUID()
        let ghost = UUID()
        try insertTrip(id: live, in: container)
        logCarries([(ghost, live)], in: defaults)
        let ctx = ModelContext(container)
        let h = makeHidden(trip: UUID(), local: "mature", hiddenAt: Self.orphanBase)
        let p = makePinned(trip: ghost, local: "carry", pinnedAt: Self.orphanBase)
        ctx.insert(h)
        ctx.insert(p)
        try ctx.save()
        let prior = [h.id.uuidString: Self.orphanBase.timeIntervalSince1970]
        defaults.set(prior, forKey: PhotoAnnotationDeduplicator.firstObservedOrphansKey)

        let outcome = await PhotoAnnotationDeduplicator.sweepOrphans(
            modelContainer: container, now: Self.pastGrace, defaults: defaults, queueDirectory: directory)
        #expect(!outcome.completed && outcome.deleted == 0 && outcome.rekeyedOnto.isEmpty)
        #expect(try fetchHidden(container).map(\.id) == [h.id])
        #expect(try fetchPinned(container).map(\.tripID) == [ghost])
        #expect(orphanMap(defaults) == prior)
        #expect(try Data(contentsOf: queueURL) == corrupt)
    }

    @Test("spent Keep archives confer no ownership; Forget ends protection and starts the normal local orphan grace")
    func spentAndForgottenArchivesAgeNormally() async throws {
        let directory = try queueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = freshDefaults()
        let container = try TestSupport.makeInMemoryContainer()
        try insertTrip(id: UUID(), in: container)
        let forgotten = UUID()
        let spent = UUID()
        let records = [archivedTrip(forgotten), archivedTrip(spent)]
        try DissolvedTripQueue.append(records, in: directory)
        var committed = records[1]
        committed.splitCommitted = true
        try DissolvedTripQueue.append([committed], in: directory)
        try DissolvedTripQueue.markKeepCommitted(id: spent, in: directory)
        let ctx = ModelContext(container)
        for (id, local) in [(forgotten, "forgotten"), (spent, "spent")] {
            ctx.insert(makeHidden(trip: id, local: local, hiddenAt: Self.orphanBase))
            ctx.insert(makePinned(trip: id, local: local, pinnedAt: Self.orphanBase))
        }
        try ctx.save()
        let first = await PhotoAnnotationDeduplicator.sweepOrphans(
            modelContainer: container, now: Self.orphanBase, defaults: defaults, queueDirectory: directory)
        #expect(first.completed && first.deleted == 0)
        try DissolvedTripQueue.remove(ids: [forgotten], in: directory)
        let afterForget = await PhotoAnnotationDeduplicator.sweepOrphans(
            modelContainer: container, now: Self.pastGrace, defaults: defaults, queueDirectory: directory)
        #expect(afterForget.completed && afterForget.deleted == 2)
        #expect(try fetchHidden(container).map(\.tripID) == [forgotten])
        #expect(try fetchPinned(container).map(\.tripID) == [forgotten])
        let later = await PhotoAnnotationDeduplicator.sweepOrphans(
            modelContainer: container, now: Self.pastGrace.addingTimeInterval(25 * 3600),
            defaults: defaults, queueDirectory: directory)
        #expect(later.completed && later.deleted == 2)
        #expect(try fetchHidden(container).isEmpty)
        #expect(try fetchPinned(container).isEmpty)
    }

    @Test("a row keyed to a carried ghost moves to the winner at once and is never aged out")
    func carriedGhostRowsFollowTheWinner() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let defaults = freshDefaults()
        let ghost = UUID()
        let winner = UUID()
        try insertTrip(id: winner, in: container)
        logCarries([(ghost, winner)], in: defaults)
        let ctx = ModelContext(container)
        ctx.insert(makeHidden(trip: ghost, local: "h", hiddenAt: Self.orphanBase))
        ctx.insert(makePinned(trip: ghost, local: "p", pinnedAt: Self.orphanBase))
        try ctx.save()

        let first = await PhotoAnnotationDeduplicator.sweepOrphans(
            modelContainer: container, now: Self.orphanBase, defaults: defaults)
        #expect(first.completed)
        #expect(first.rekeyedOnto == [winner])
        #expect(first.deleted == 0)
        #expect(try fetchHidden(container).map(\.tripID) == [winner])
        #expect(try fetchPinned(container).map(\.tripID) == [winner])
        #expect(orphanMap(defaults) == nil)

        let later = await PhotoAnnotationDeduplicator.sweepOrphans(
            modelContainer: container, now: Self.pastGrace, defaults: defaults)
        #expect(later.completed)
        #expect(later.rekeyedOnto.isEmpty)
        #expect(try fetchHidden(container).map(\.tripID) == [winner])
        #expect(try fetchPinned(container).map(\.tripID) == [winner])
    }

    @Test("a late row follows the carry chain to its existing end")
    func carriedGhostRowsFollowTheChain() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let defaults = freshDefaults()
        let ghost = UUID()
        let middle = UUID()
        let end = UUID()
        try insertTrip(id: end, in: container)
        logCarries([(ghost, middle), (middle, end)], in: defaults)
        let ctx = ModelContext(container)
        ctx.insert(makeHidden(trip: ghost, local: "h", hiddenAt: Self.orphanBase))
        try ctx.save()

        let sweep = await PhotoAnnotationDeduplicator.sweepOrphans(
            modelContainer: container, now: Self.orphanBase, defaults: defaults)
        #expect(sweep.rekeyedOnto == [end])
        #expect(try fetchHidden(container).map(\.tripID) == [end])
    }

    @Test("a row keyed to a ghost UUID that has a row again is left where it is")
    func restoredGhostKeepsItsRows() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let defaults = freshDefaults()
        let ghost = UUID()
        let winner = UUID()
        try insertTrip(id: ghost, in: container)
        try insertTrip(id: winner, in: container)
        logCarries([(ghost, winner)], in: defaults)
        let ctx = ModelContext(container)
        ctx.insert(makeHidden(trip: ghost, local: "h", hiddenAt: Self.orphanBase))
        try ctx.save()

        let sweep = await PhotoAnnotationDeduplicator.sweepOrphans(
            modelContainer: container, now: Self.pastGrace, defaults: defaults)
        #expect(sweep.completed)
        #expect(sweep.rekeyedOnto.isEmpty)
        #expect(try fetchHidden(container).map(\.tripID) == [ghost])
    }

    @Test("a logged ghost whose winner is missing ages as an orphan and follows the winner if it arrives")
    func missingWinnerAgesThenFollowsWhenItArrives() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let defaults = freshDefaults()
        let ghost = UUID()
        let winner = UUID()
        try insertTrip(id: UUID(), in: container)
        // Malformed entries and a two-ghost loop resolve to nothing.
        defaults.set(["garbage", "\(ghost.uuidString) \(winner.uuidString)",
                      "\(winner.uuidString) \(ghost.uuidString)"],
                     forKey: TripDeduplicator.carriedFavouritesKey)
        let ctx = ModelContext(container)
        ctx.insert(makeHidden(trip: ghost, local: "h", hiddenAt: Self.orphanBase))
        try ctx.save()

        let observed = await PhotoAnnotationDeduplicator.sweepOrphans(
            modelContainer: container, now: Self.orphanBase, defaults: defaults)
        #expect(observed.completed)
        #expect(observed.rekeyedOnto.isEmpty)
        #expect(try fetchHidden(container).map(\.tripID) == [ghost])
        #expect(orphanMap(defaults)?.count == 1)

        try insertTrip(id: winner, in: container)
        let followed = await PhotoAnnotationDeduplicator.sweepOrphans(
            modelContainer: container, now: Self.orphanBase.addingTimeInterval(3600), defaults: defaults)
        #expect(followed.rekeyedOnto == [winner])
        #expect(try fetchHidden(container).map(\.tripID) == [winner])
        #expect(orphanMap(defaults) == nil)
    }

    @Test("a device without the carry log treats a late ghost row as an ordinary orphan")
    func carryLogIsDeviceLocal() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let carrier = freshDefaults()
        let other = freshDefaults()
        let ghost = UUID()
        let winner = UUID()
        try insertTrip(id: winner, in: container)
        logCarries([(ghost, winner)], in: carrier)
        let ctx = ModelContext(container)
        ctx.insert(makeHidden(trip: ghost, local: "h", hiddenAt: Self.orphanBase))
        try ctx.save()

        // The documented limitation: only the carrying device can replay.
        let first = await PhotoAnnotationDeduplicator.sweepOrphans(
            modelContainer: container, now: Self.orphanBase, defaults: other)
        #expect(first.rekeyedOnto.isEmpty)
        let second = await PhotoAnnotationDeduplicator.sweepOrphans(
            modelContainer: container, now: Self.pastGrace, defaults: other)
        #expect(second.deleted == 1)
        #expect(try fetchHidden(container).isEmpty)
    }

    @Test("a failed annotation read changes neither the store nor the observations",
          arguments: [PhotoAnnotationDeduplicator.OrphanSweepFault.hiddenRead, .pinnedRead])
    func annotationReadFailureChangesNothing(fault: PhotoAnnotationDeduplicator.OrphanSweepFault) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let defaults = freshDefaults()
        let ghost = UUID()
        let winner = UUID()
        try insertTrip(id: winner, in: container)
        logCarries([(ghost, winner)], in: defaults)
        let ctx = ModelContext(container)
        let mature = makeHidden(trip: UUID(), local: "mature", hiddenAt: Self.orphanBase)
        ctx.insert(mature)
        ctx.insert(makePinned(trip: ghost, local: "late", pinnedAt: Self.orphanBase))
        try ctx.save()
        let prior = [mature.id.uuidString: Self.orphanBase.timeIntervalSince1970]
        defaults.set(prior, forKey: PhotoAnnotationDeduplicator.firstObservedOrphansKey)

        let sweep = await PhotoAnnotationDeduplicator.$orphanSweepFaultForTesting.withValue(fault) {
            await PhotoAnnotationDeduplicator.sweepOrphans(
                modelContainer: container, now: Self.pastGrace, defaults: defaults)
        }
        #expect(!sweep.completed)
        #expect(sweep.rekeyedOnto.isEmpty)
        #expect(try fetchHidden(container).map(\.localIdentifier) == ["mature"])
        #expect(try fetchPinned(container).map(\.tripID) == [ghost])
        #expect(orphanMap(defaults) == prior)
    }

    @Test("a failed save keeps the rows and prior observations, and a retry completes the replay")
    func saveFailureKeepsStateForRetry() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let defaults = freshDefaults()
        let ghost = UUID()
        let winner = UUID()
        try insertTrip(id: winner, in: container)
        logCarries([(ghost, winner)], in: defaults)
        let ctx = ModelContext(container)
        let waiting = makeHidden(trip: UUID(), local: "waiting", hiddenAt: Self.orphanBase)
        ctx.insert(waiting)
        ctx.insert(makePinned(trip: ghost, local: "late", pinnedAt: Self.orphanBase))
        try ctx.save()
        let prior = [waiting.id.uuidString: Self.orphanBase.timeIntervalSince1970]
        defaults.set(prior, forKey: PhotoAnnotationDeduplicator.firstObservedOrphansKey)
        let withinGrace = Self.orphanBase.addingTimeInterval(3600)

        let failed = await PhotoAnnotationDeduplicator.$orphanSweepFaultForTesting.withValue(.save) {
            await PhotoAnnotationDeduplicator.sweepOrphans(
                modelContainer: container, now: withinGrace, defaults: defaults)
        }
        #expect(!failed.completed)
        #expect(failed.rekeyedOnto.isEmpty)
        #expect(try fetchPinned(container).map(\.tripID) == [ghost])
        #expect(orphanMap(defaults) == prior)

        let retried = await PhotoAnnotationDeduplicator.sweepOrphans(
            modelContainer: container, now: withinGrace, defaults: defaults)
        #expect(retried.completed)
        #expect(retried.rekeyedOnto == [winner])
        #expect(try fetchPinned(container).map(\.tripID) == [winner])
        #expect(try fetchHidden(container).map(\.localIdentifier) == ["waiting"])
        #expect(orphanMap(defaults) == prior)
    }
}
