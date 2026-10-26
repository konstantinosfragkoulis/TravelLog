//
//  P06RegressionTests.swift
//  TravelLogTests
//
//  Sync ownership and restore lifecycle: which physical row or account owns
//  a synced choice, and what a restored device may still trust.
//
//  The duplicate-sweep cases extend `TripDeduplicatorTests`: they share its
//  process-wide single-flight lock and test hooks, so they must run in that
//  serialized suite.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

// MARK: - Fixtures

@MainActor
private enum P06Fixture {
    static let day: TimeInterval = 24 * 60 * 60
    static let base = Date(timeIntervalSinceReferenceDate: 610 * day)

    static func date(day offset: Double) -> Date {
        base.addingTimeInterval(offset * day)
    }

    static func makeDefaults() -> UserDefaults {
        let suite = "P06RegressionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @discardableResult
    static func makeTrip(
        in ctx: ModelContext, startDay: Double, endDay: Double?,
        complete: Bool = true, customName: String? = nil, id: UUID? = nil
    ) -> Trip {
        let trip = Trip(startDate: date(day: startDay))
        if let id { trip.id = id }
        trip.endDate = endDay.map { date(day: $0) }
        trip.isComplete = complete
        trip.customName = customName
        trip.destinationSummary = "Harbour Town"
        trip.countryCodes = "IT"
        ctx.insert(trip)
        return trip
    }

    @discardableResult
    static func makeStay(in ctx: ModelContext, day: Double, trip: Trip?) -> Stay {
        let start = date(day: day)
        let stay = Stay(
            startTime: start, endTime: start.addingTimeInterval(6 * 3600),
            centroidLatitude: 44.3, centroidLongitude: 12.9,
            h3IndexRes6: "P06", pingCount: 3, distanceFromHomeKm: 900, pingIDs: [])
        stay.category = .destination
        stay.trip = trip
        ctx.insert(stay)
        return stay
    }
}

/// Resolves Application Support to a throwaway directory, so the restore
/// sentinel can be driven without touching the app container.
private final class P06SupportDirectory: FileManager {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
        super.init()
    }

    override func urls(
        for directory: FileManager.SearchPathDirectory,
        in domainMask: FileManager.SearchPathDomainMask
    ) -> [URL] {
        [self.directory]
    }
}

// MARK: - ID-001 / ID-002: populated same-UUID twin ownership

extension TripDeduplicatorTests {

    /// Ghost G (UUID X) matches winner W. A populated physical X twin syncs in
    /// while the sweep waits for the main actor, after G's carry was prepared.
    @Test("A populated twin that syncs in during the favourite recheck keeps the ghost's photo choices")
    func p06LateTwinSuppressesPreparedCarry() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let winner = P06Fixture.makeTrip(in: ctx, startDay: 0, endDay: 4)
        P06Fixture.makeStay(in: ctx, day: 1, trip: winner)
        let ghost = P06Fixture.makeTrip(in: ctx, startDay: 0, endDay: 4)
        let sharedID = ghost.id
        let winnerID = winner.id
        ctx.insert(HiddenPhoto(localIdentifier: "p06-hidden", tripID: sharedID))
        ctx.insert(PinnedPhoto(localIdentifier: "p06-pinned", tripID: sharedID))
        try ctx.save()
        let ghostRowID = ghost.persistentModelID
        let defaults = P06Fixture.makeDefaults()
        let pins = PinnedTripsStorage(forTesting: P06Fixture.makeDefaults())
        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: P06Fixture.date(day: 40), defaults: defaults, pins: pins)

        var preparedCarry = false
        TripDeduplicator.beforeFavouriteRecheckForTesting = { preparedIDs, photoCount in
            preparedCarry = preparedIDs == [sharedID] && photoCount == 2
            let other = ModelContext(container)
            let twin = P06Fixture.makeTrip(in: other, startDay: 0, endDay: 4, id: sharedID)
            P06Fixture.makeStay(in: other, day: 2, trip: twin)
            try? other.save()
        }
        defer { TripDeduplicator.beforeFavouriteRecheckForTesting = nil }
        let outcome = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: P06Fixture.date(day: 42), defaults: defaults, pins: pins)

        #expect(preparedCarry, "the carry onto W was prepared before the twin arrived")
        #expect(outcome.deleted == 1)
        #expect(outcome.carried.isEmpty)
        let fresh = ModelContext(container)
        let remaining = try fresh.fetch(FetchDescriptor<Trip>())
        #expect(!remaining.contains { $0.persistentModelID == ghostRowID })
        #expect(remaining.contains { $0.id == sharedID && !($0.stays ?? []).isEmpty })
        #expect(try fresh.fetch(FetchDescriptor<HiddenPhoto>()).map(\.tripID) == [sharedID])
        #expect(try fresh.fetch(FetchDescriptor<PinnedPhoto>()).map(\.tripID) == [sharedID])
        #expect(!pins.isPinned(winnerID))
        #expect(TripDeduplicator.carriedWinners(defaults: defaults).isEmpty)
    }

    @Test("An empty copy of a favourite trip goes once its populated twin owns the favourite",
          arguments: [false, true])
    func p06TwinOwnedFavouriteDoesNotKeepGhost(twinArrivesDuringSweep: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let winner = P06Fixture.makeTrip(in: ctx, startDay: 0, endDay: 4)
        P06Fixture.makeStay(in: ctx, day: 1, trip: winner)
        let ghost = P06Fixture.makeTrip(in: ctx, startDay: 0, endDay: 4)
        let sharedID = ghost.id
        let winnerID = winner.id
        var twinRowID: PersistentIdentifier?
        func insertTwin(into context: ModelContext) {
            let twin = P06Fixture.makeTrip(in: context, startDay: 0, endDay: 4, id: sharedID)
            P06Fixture.makeStay(in: context, day: 2, trip: twin)
            try? context.save()
            twinRowID = twin.persistentModelID
        }
        if !twinArrivesDuringSweep { insertTwin(into: ctx) }
        try ctx.save()
        let ghostRowID = ghost.persistentModelID
        let defaults = P06Fixture.makeDefaults()
        let pins = PinnedTripsStorage(forTesting: P06Fixture.makeDefaults())
        pins.pin(sharedID)
        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: P06Fixture.date(day: 40), defaults: defaults, pins: pins)
        if twinArrivesDuringSweep {
            TripDeduplicator.beforeFavouriteRecheckForTesting = { _, _ in
                insertTwin(into: ModelContext(container))
            }
        }
        defer { TripDeduplicator.beforeFavouriteRecheckForTesting = nil }
        let outcome = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: P06Fixture.date(day: 42), defaults: defaults, pins: pins)

        #expect(outcome.deleted == 1)
        #expect(outcome.carried.isEmpty)
        let remaining = try ModelContext(container).fetch(FetchDescriptor<Trip>()).map(\.persistentModelID)
        #expect(!remaining.contains(ghostRowID))
        #expect(remaining.contains(try #require(twinRowID)))
        #expect(pins.isPinned(sharedID))
        #expect(!pins.isPinned(winnerID))
    }

    @Test("A named or edited empty copy stays even when its populated twin owns the favourite",
          arguments: ["name", "edited"])
    func p06TwinOwnedFavouriteKeepsRowLocalEdits(_ edit: String) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let ghost = P06Fixture.makeTrip(in: ctx, startDay: 0, endDay: 4,
                                        customName: edit == "name" ? "Spring break" : nil)
        ghost.userEdited = edit == "edited"
        let sharedID = ghost.id
        let twin = P06Fixture.makeTrip(in: ctx, startDay: 0, endDay: 4, id: sharedID)
        P06Fixture.makeStay(in: ctx, day: 1, trip: twin)
        try ctx.save()
        let ghostRowID = ghost.persistentModelID
        let defaults = P06Fixture.makeDefaults()
        let pins = PinnedTripsStorage(forTesting: P06Fixture.makeDefaults())
        pins.pin(sharedID)
        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: P06Fixture.date(day: 40), defaults: defaults, pins: pins)
        let outcome = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: P06Fixture.date(day: 42), defaults: defaults, pins: pins)
        #expect(outcome.deleted == 0)
        #expect(try ModelContext(container).fetch(FetchDescriptor<Trip>()).contains { $0.persistentModelID == ghostRowID })
        #expect(pins.isPinned(sharedID))
    }

    @Test("A failed ownership re-read retains every ghost and its photo choices")
    func p06OwnershipReadFailureRetains() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let winner = P06Fixture.makeTrip(in: ctx, startDay: 0, endDay: 4)
        P06Fixture.makeStay(in: ctx, day: 1, trip: winner)
        let ghost = P06Fixture.makeTrip(in: ctx, startDay: 0, endDay: 4)
        let ghostID = ghost.id
        ctx.insert(HiddenPhoto(localIdentifier: "p06-hidden", tripID: ghostID))
        try ctx.save()
        let key = try TripDeduplicator.observationKey(for: ghost.persistentModelID)
        let defaults = P06Fixture.makeDefaults()
        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: P06Fixture.date(day: 40), defaults: defaults)
        let outcome = await TripDeduplicator.$ownershipReadFailsForTesting.withValue(true) {
            await TripDeduplicator.deduplicateAll(
                modelContainer: container, now: P06Fixture.date(day: 42), defaults: defaults)
        }
        #expect(outcome.deleted == 0)
        #expect(outcome.incomplete)
        #expect(try ModelContext(container).fetch(FetchDescriptor<Trip>()).contains { $0.id == ghostID })
        #expect(try ModelContext(container).fetch(FetchDescriptor<HiddenPhoto>()).map(\.tripID) == [ghostID])
        #expect(defaults.dictionary(forKey: TripDeduplicator.firstObservedGhostsKey)?[key] as? Double
            == P06Fixture.date(day: 40).timeIntervalSince1970)
    }
}

// MARK: - Sync ownership and restore lifecycle

@MainActor
@Suite("Sync ownership and restore lifecycle")
struct P06RegressionTests {

    // MARK: MULTI-003: orphan grace follows the physical row

    private static let orphanBase = P06Fixture.date(day: 100)

    private func orphanMap(_ defaults: UserDefaults) -> [String: Double] {
        (defaults.dictionary(forKey: PhotoAnnotationDeduplicator.firstObservedOrphansKey) as? [String: Double]) ?? [:]
    }

    /// One unrelated trip keeps the empty-store guard open.
    private func orphanStore() throws -> ModelContainer {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        P06Fixture.makeTrip(in: ctx, startDay: 0, endDay: 2)
        try ctx.save()
        return container
    }

    private func insertChoice(
        hidden: Bool, id: UUID, trip: UUID, local: String, in container: ModelContainer
    ) throws -> PersistentIdentifier {
        let ctx = ModelContext(container)
        if hidden {
            let row = HiddenPhoto(localIdentifier: local, tripID: trip)
            row.id = id
            ctx.insert(row)
            try ctx.save()
            return row.persistentModelID
        }
        let row = PinnedPhoto(localIdentifier: local, tripID: trip)
        row.id = id
        ctx.insert(row)
        try ctx.save()
        return row.persistentModelID
    }

    private func choiceRows(
        hidden: Bool, in container: ModelContainer
    ) throws -> [(row: PersistentIdentifier, trip: UUID)] {
        let ctx = ModelContext(container)
        if hidden {
            return try ctx.fetch(FetchDescriptor<HiddenPhoto>()).map { ($0.persistentModelID, $0.tripID) }
        }
        return try ctx.fetch(FetchDescriptor<PinnedPhoto>()).map { ($0.persistentModelID, $0.tripID) }
    }

    @Test("A physical twin that syncs in under a mature orphan's UUID ages from its own arrival",
          arguments: [true, false])
    func newPhysicalTwinGetsItsOwnGrace(hidden: Bool) async throws {
        let container = try orphanStore()
        let defaults = P06Fixture.makeDefaults()
        let choiceID = UUID()
        let lateOwner = UUID()
        _ = try insertChoice(hidden: hidden, id: choiceID, trip: UUID(), local: "p06-old", in: container)
        let first = await PhotoAnnotationDeduplicator.sweepOrphans(
            modelContainer: container, now: Self.orphanBase, defaults: defaults)
        #expect(first.completed && first.deleted == 0)

        // A copy restored on another device arrives keyed to its own owner,
        // whose trip has not synced in yet.
        let arrival = Self.orphanBase.addingTimeInterval(25 * 3600)
        let twin = try insertChoice(hidden: hidden, id: choiceID, trip: lateOwner, local: "p06-old", in: container)
        let second = await PhotoAnnotationDeduplicator.sweepOrphans(
            modelContainer: container, now: arrival, defaults: defaults)
        #expect(second.completed && second.deleted == 1)
        #expect(try choiceRows(hidden: hidden, in: container).map { $0.row } == [twin])

        let ctx = ModelContext(container)
        P06Fixture.makeTrip(in: ctx, startDay: 10, endDay: 12, id: lateOwner)
        try ctx.save()
        let third = await PhotoAnnotationDeduplicator.sweepOrphans(
            modelContainer: container, now: arrival.addingTimeInterval(25 * 3600), defaults: defaults)
        #expect(third.completed && third.deleted == 0)
        #expect(try choiceRows(hidden: hidden, in: container).map { $0.trip } == [lateOwner])
        #expect(orphanMap(defaults).isEmpty)
    }

    @Test("A legacy UUID clock grants fresh physical-row grace and is pruned")
    func legacyOrphanClockStartsFresh() async throws {
        let container = try orphanStore()
        let defaults = P06Fixture.makeDefaults()
        let choiceID = UUID()
        let row = try insertChoice(hidden: true, id: choiceID, trip: UUID(), local: "p06-legacy", in: container)
        defaults.set([choiceID.uuidString: Self.orphanBase.timeIntervalSince1970],
                     forKey: PhotoAnnotationDeduplicator.firstObservedOrphansKey)
        let now = Self.orphanBase.addingTimeInterval(48 * 3600)
        let outcome = await PhotoAnnotationDeduplicator.sweepOrphans(
            modelContainer: container, now: now, defaults: defaults)
        #expect(outcome.completed && outcome.deleted == 0)
        let key = try PhotoAnnotationDeduplicator.orphanObservationKey(model: "HiddenPhoto", identifier: row)
        #expect(orphanMap(defaults) == [key: now.timeIntervalSince1970])
        #expect(try PhotoAnnotationDeduplicator.orphanObservationKey(model: "PinnedPhoto", identifier: row) != key)
    }

    @Test("An unencodable row identity is never aged or deleted")
    func unencodableOrphanIdentityIsKept() async throws {
        let container = try orphanStore()
        let defaults = P06Fixture.makeDefaults()
        _ = try insertChoice(hidden: true, id: UUID(), trip: UUID(), local: "p06-h", in: container)
        _ = try insertChoice(hidden: false, id: UUID(), trip: UUID(), local: "p06-p", in: container)
        for offset in [0.0, 30, 60] {
            let outcome = await PhotoAnnotationDeduplicator.$orphanSweepFaultForTesting.withValue(.identityEncoding) {
                await PhotoAnnotationDeduplicator.sweepOrphans(
                    modelContainer: container, now: Self.orphanBase.addingTimeInterval(offset * 3600),
                    defaults: defaults)
            }
            #expect(outcome.completed && outcome.deleted == 0)
        }
        #expect(try choiceRows(hidden: true, in: container).count == 1)
        #expect(try choiceRows(hidden: false, in: container).count == 1)
        #expect(orphanMap(defaults).isEmpty)
    }

    // MARK: PERM-001: an iCloud account change replaces the KVS sets

    /// The KVS keys the isolated test storages read and write.
    private static let pinsKey = "pinnedTripIDs"
    private static let countriesKey = "rememberedCountryCodes"

    private func storeStrings(_ strings: [String], key: String, in defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(strings.sorted()), forKey: key)
    }

    private func storedStrings(key: String, in defaults: UserDefaults) throws -> Set<String>? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return Set(try JSONDecoder().decode([String].self, from: data))
    }

    @Test("A favourite edited after an iCloud account change lands on the new account's set only",
          arguments: [false, true])
    func favouriteEditAfterAccountChange(newAccountHasFavourites: Bool) throws {
        let defaults = P06Fixture.makeDefaults()
        let previous = UUID()
        try storeStrings([previous.uuidString], key: Self.pinsKey, in: defaults)
        let pins = PinnedTripsStorage(forTesting: defaults)
        #expect(pins.pinnedIDs == [previous])

        // KVS replaced the local values with the new account's, and the
        // observer counted it; its main-actor handler has not run yet.
        let existing = UUID()
        if newAccountHasFavourites {
            try storeStrings([existing.uuidString], key: Self.pinsKey, in: defaults)
        } else {
            defaults.removeObject(forKey: Self.pinsKey)
        }
        pins.noteAccountChangeForTesting()
        let edit = UUID()
        pins.pin(edit)
        let expected: Set<UUID> = newAccountHasFavourites ? [existing, edit] : [edit]
        #expect(pins.pinnedIDs == expected)
        #expect(try storedStrings(key: Self.pinsKey, in: defaults) == Set(expected.map(\.uuidString)))
    }

    @Test("The account-change handler adopts a missing key as empty; an ordinary missing key keeps the known set")
    func accountChangeHandlerAdoptsEmptyAccount() throws {
        let defaults = P06Fixture.makeDefaults()
        let known = UUID()
        try storeStrings([known.uuidString], key: Self.pinsKey, in: defaults)
        try storeStrings(["IT"], key: Self.countriesKey, in: defaults)
        let pins = PinnedTripsStorage(forTesting: defaults)
        let countries = RememberedCountriesStorage(forTesting: defaults)

        // Same account, value not delivered yet: nothing is adopted or lost.
        defaults.removeObject(forKey: Self.pinsKey)
        defaults.removeObject(forKey: Self.countriesKey)
        pins.adoptAccountChanges()
        countries.adoptAccountChanges()
        #expect(pins.pinnedIDs == [known])
        #expect(countries.codes == ["IT"])

        pins.noteAccountChangeForTesting()
        countries.noteAccountChangeForTesting()
        pins.adoptAccountChanges()
        countries.adoptAccountChanges()
        #expect(pins.pinnedIDs.isEmpty)
        #expect(countries.codes.isEmpty)
        // Adoption reads; it never writes the new account's store.
        #expect(defaults.data(forKey: Self.pinsKey) == nil)
        #expect(defaults.data(forKey: Self.countriesKey) == nil)
    }

    @Test("A remembered country toggled after an iCloud account change keeps the new account's list and the user's intent")
    func countryToggleAfterAccountChange() throws {
        let defaults = P06Fixture.makeDefaults()
        try storeStrings(["IT", "FR"], key: Self.countriesKey, in: defaults)
        let countries = RememberedCountriesStorage(forTesting: defaults)
        try storeStrings(["JP"], key: Self.countriesKey, in: defaults)
        countries.noteAccountChangeForTesting()
        // The user saw Italy ticked and unticked it: the new account must
        // neither gain Italy nor receive France.
        countries.toggle("IT")
        #expect(countries.codes == ["JP"])
        #expect(try storedStrings(key: Self.countriesKey, in: defaults) == ["JP"])
        countries.toggle("DE")
        #expect(try storedStrings(key: Self.countriesKey, in: defaults) == ["JP", "DE"])
    }

    // MARK: SYNC-003: explicit edits start from the delivered set

    @Test("A favourite edit keeps delivered additions and removals its notification has not applied yet")
    func favouriteEditsKeepDeliveredChanges() throws {
        let defaults = P06Fixture.makeDefaults()
        let a = UUID(), b = UUID(), c = UUID()
        try storeStrings([a.uuidString], key: Self.pinsKey, in: defaults)
        let pins = PinnedTripsStorage(forTesting: defaults)

        // Another device added B; this cache still shows only A.
        try storeStrings([a.uuidString, b.uuidString], key: Self.pinsKey, in: defaults)
        pins.pin(c)
        #expect(try storedStrings(key: Self.pinsKey, in: defaults) == Set([a, b, c].map(\.uuidString)))

        // Another device removed B; unpinning A must not bring it back.
        try storeStrings([a.uuidString, c.uuidString], key: Self.pinsKey, in: defaults)
        #expect(pins.isPinned(b))
        pins.unpin(a)
        #expect(try storedStrings(key: Self.pinsKey, in: defaults) == [c.uuidString])

        // Delivered pin of B while the screen still showed it unpinned: the
        // tap meant "favourite", so B stays a favourite.
        try storeStrings([b.uuidString, c.uuidString], key: Self.pinsKey, in: defaults)
        #expect(!pins.isPinned(b))
        pins.toggle(b)
        #expect(try storedStrings(key: Self.pinsKey, in: defaults) == Set([b, c].map(\.uuidString)))

        // A missing value is not absence: the known set is kept.
        defaults.removeObject(forKey: Self.pinsKey)
        pins.pin(a)
        #expect(try storedStrings(key: Self.pinsKey, in: defaults) == Set([a, b, c].map(\.uuidString)))
    }

    @Test("A remembered-country toggle keeps delivered changes and the intent the user saw")
    func countryToggleKeepsDeliveredChanges() throws {
        let defaults = P06Fixture.makeDefaults()
        try storeStrings(["IT"], key: Self.countriesKey, in: defaults)
        let countries = RememberedCountriesStorage(forTesting: defaults)

        try storeStrings(["IT", "FR"], key: Self.countriesKey, in: defaults)
        countries.toggle("DE")
        #expect(try storedStrings(key: Self.countriesKey, in: defaults) == ["IT", "FR", "DE"])

        // France was removed elsewhere; adding Japan must not restore it.
        try storeStrings(["IT", "DE"], key: Self.countriesKey, in: defaults)
        countries.toggle("JP")
        #expect(try storedStrings(key: Self.countriesKey, in: defaults) == ["IT", "DE", "JP"])

        // Spain arrived while the list still showed it unticked; ticking it keeps it.
        try storeStrings(["IT", "DE", "JP", "ES"], key: Self.countriesKey, in: defaults)
        #expect(!countries.contains("ES"))
        countries.toggle("ES")
        #expect(try storedStrings(key: Self.countriesKey, in: defaults) == ["IT", "DE", "JP", "ES"])
        countries.toggle("xx")
        #expect(try storedStrings(key: Self.countriesKey, in: defaults) == ["IT", "DE", "JP", "ES"])
    }

    // MARK: WIPE-002: the restore marker is published only once excluded

    private func supportDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("P06RegressionTests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("A restore marker reaches its final path only after its backup exclusion",
          arguments: [RestoreSentinel.SetupFault.afterCreate, .exclusion, .publish])
    func restoreMarkerPublishedOnlyExcluded(fault: RestoreSentinel.SetupFault) throws {
        for restored in [false, true] {
            let directory = supportDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileManager = P06SupportDirectory(directory: directory)
            let defaults = P06Fixture.makeDefaults()
            defaults.set(restored, forKey: RestoreSentinel.flagKey)
            let marker = directory.appendingPathComponent(RestoreSentinel.sentinelFilename)
            let pending = directory.appendingPathComponent(RestoreSentinel.pendingFilename)

            let interrupted = RestoreSentinel.$setupFaultForTesting.withValue(fault) {
                RestoreSentinel.consumeRestoreDetection(defaults: defaults, fileManager: fileManager)
            }
            #expect(interrupted == restored)
            #expect(!FileManager.default.fileExists(atPath: marker.path))
            #expect(defaults.bool(forKey: RestoreSentinel.flagKey) == restored)
            // A restored launch stays a restore rather than reading as set up.
            #expect(RestoreSentinel.isRestorePending(defaults: defaults, fileManager: fileManager) == restored)

            #expect(RestoreSentinel.consumeRestoreDetection(defaults: defaults, fileManager: fileManager) == restored)
            #expect(FileManager.default.fileExists(atPath: marker.path))
            #expect(!FileManager.default.fileExists(atPath: pending.path))
            #expect(defaults.bool(forKey: RestoreSentinel.flagKey))
            #expect(!RestoreSentinel.consumeRestoreDetection(defaults: defaults, fileManager: fileManager))

            // A later backup restore brings the flag back without the marker.
            try FileManager.default.removeItem(at: marker)
            #expect(RestoreSentinel.isRestorePending(defaults: defaults, fileManager: fileManager))
        }
    }

    // MARK: MULTI-004: a restored device gets its own import-fence identity

    @Test("A restored device warns about a file the original device imported after the backup")
    func restoredDeviceWarnsForDeliveredFence() throws {
        let directory = supportDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileManager = P06SupportDirectory(directory: directory)
        let defaults = P06Fixture.makeDefaults()
        // The backup predates file F: it carries the original's identity and
        // the sentinel flag, but not the excluded marker.
        let original = ImportFence.deviceID(defaults: defaults)
        defaults.set(true, forKey: RestoreSentinel.flagKey)
        let fingerprint = ImportFence.fingerprint(of: Data("p06-file".utf8))
        let delivered = [ImportFence.Record(fingerprint: fingerprint, deviceID: original, date: P06Fixture.base)]
        #expect(!ImportFence.isCrossDeviceRepeat(
            records: delivered, fingerprint: fingerprint, deviceID: ImportFence.deviceID(defaults: defaults)))

        #expect(RestoreSentinel.consumeRestoreDetection(defaults: defaults, fileManager: fileManager))
        let restored = ImportFence.deviceID(defaults: defaults)
        #expect(restored != original)
        #expect(ImportFence.isCrossDeviceRepeat(records: delivered, fingerprint: fingerprint, deviceID: restored))
        #expect(!ImportFence.isCrossDeviceRepeat(
            records: delivered, fingerprint: ImportFence.fingerprint(of: Data("p06-other".utf8)), deviceID: restored))

        // Ordinary relaunches keep the new identity, so its own re-imports stay silent.
        #expect(!RestoreSentinel.consumeRestoreDetection(defaults: defaults, fileManager: fileManager))
        #expect(ImportFence.deviceID(defaults: defaults) == restored)
    }

    // MARK: SYNC-004: one content donor per recap year

    @Test("Tied newer recap generations give the survivor the same content in every fetch order")
    func recapDonorIndependentOfFetchOrder() async throws {
        let a = try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000000A"))
        let b = try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000000B"))
        let z = try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000000F"))
        let older = P06Fixture.date(day: 200)
        let newer = P06Fixture.date(day: 201)
        let orders: [[UUID]] = [[a, b, z], [a, z, b], [b, a, z], [b, z, a], [z, a, b], [z, b, a]]
        for order in orders {
            let container = try TestSupport.makeInMemoryContainer()
            let ctx = ModelContext(container)
            for id in order {
                let row = YearWrapped(year: 2031)
                row.id = id
                row.generatedAt = id == z ? older : newer
                row.yearNarrative = "narrative-\(id.uuidString.suffix(1))"
                row.yearNarrativeSourceRaw = "source-\(id.uuidString.suffix(1))"
                row.statsData = Data(id.uuidString.utf8)
                row.weatherCoverage = id == a ? 0.25 : (id == b ? 0.5 : 0.75)
                row.transitCoverage = id == a ? 0.1 : (id == b ? 0.2 : 0.3)
                row.viewedAt = id == a ? P06Fixture.date(day: 203) : (id == z ? P06Fixture.date(day: 202) : nil)
                ctx.insert(row)
            }
            try ctx.save()
            #expect(await YearWrappedDeduplicator.deduplicateAll(modelContainer: container))
            let rows = try ModelContext(container).fetch(FetchDescriptor<YearWrapped>())
            let survivor = try #require(rows.first)
            #expect(rows.count == 1)
            #expect(survivor.id == z)
            #expect(survivor.yearNarrative == "narrative-B")
            #expect(survivor.yearNarrativeSourceRaw == "source-B")
            #expect(survivor.statsData == Data(b.uuidString.utf8))
            #expect(survivor.weatherCoverage == 0.5)
            #expect(survivor.transitCoverage == 0.2)
            #expect(survivor.generatedAt == newer)
            #expect(survivor.viewedAt == P06Fixture.date(day: 202))
            // A second pass is idempotent.
            #expect(await YearWrappedDeduplicator.deduplicateAll(modelContainer: container))
            #expect(try ModelContext(container).fetch(FetchDescriptor<YearWrapped>()).first?.yearNarrative == "narrative-B")
        }
    }

    // MARK: Hidden-photo lineage for regrouped trips (HIST-002 support)

    @Test("A regroup's hidden choices are inherited once per successor, coalesced and independently removable")
    func lineageInheritsHiddenChoices() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let retired = UUID(), first = UUID(), second = UUID()
        let early = P06Fixture.date(day: 300)
        let late = P06Fixture.date(day: 301)
        for (local, cloud, at) in [("p06-a", "cloud-a", late), ("p06-a", nil, early), ("p06-b", nil, early)]
            as [(String, String?, Date)] {
            let row = HiddenPhoto(localIdentifier: local, tripID: retired)
            row.cloudIdentifier = cloud
            row.hiddenAt = at
            ctx.insert(row)
        }
        let held = HiddenPhoto(localIdentifier: "p06-b-other-device", tripID: second)
        held.cloudIdentifier = nil
        ctx.insert(held)
        let heldLocal = HiddenPhoto(localIdentifier: "p06-b", tripID: second)
        ctx.insert(heldLocal)
        try ctx.save()

        let choices = try PhotoLineageStore.hiddenChoices(of: [retired], in: ctx)
        #expect(choices[retired]?.count == 3)
        let snapshot = try #require(choices[retired])
        #expect(try PhotoLineageStore.inheritHidden(snapshot, onto: first, in: ctx) == 2)
        #expect(try PhotoLineageStore.inheritHidden(snapshot, onto: second, in: ctx) == 1)
        // Unsaved copies already count as held.
        #expect(try PhotoLineageStore.inheritHidden(snapshot, onto: first, in: ctx) == 0)
        try ctx.save()

        let fresh = ModelContext(container)
        let onFirst = try fresh.fetch(FetchDescriptor<HiddenPhoto>()).filter { $0.tripID == first }
        #expect(Set(onFirst.map(\.localIdentifier)) == ["p06-a", "p06-b"])
        let copiedA = try #require(onFirst.first { $0.localIdentifier == "p06-a" })
        #expect(copiedA.cloudIdentifier == "cloud-a")
        #expect(copiedA.hiddenAt == early)
        #expect(Set(onFirst.map(\.id)).isDisjoint(with: try fresh.fetch(FetchDescriptor<HiddenPhoto>())
            .filter { $0.tripID == retired }.map(\.id)))

        // Unhiding on one successor leaves the other's copy alone.
        fresh.delete(copiedA)
        try fresh.save()
        let remaining = try ModelContext(container).fetch(FetchDescriptor<HiddenPhoto>())
        #expect(remaining.contains { $0.tripID == second && $0.localIdentifier == "p06-a" })
        #expect(!remaining.contains { $0.tripID == first && $0.localIdentifier == "p06-a" })
    }

    @Test("The lineage log follows later retirements, skips missing ends and restores after a failed save")
    func lineageLogChains() {
        let defaults = P06Fixture.makeDefaults()
        let retired = UUID(), kept = UUID(), passedOn = UUID(), end = UUID(), missing = UUID()
        let prior = PhotoLineageStore.record(
            [.init(retiredID: retired, successorIDs: [kept, passedOn]),
             .init(retiredID: missing, successorIDs: [missing])], defaults: defaults)
        #expect(prior == nil)
        _ = PhotoLineageStore.record([.init(retiredID: passedOn, successorIDs: [end, retired])], defaults: defaults)
        let lineage = PhotoLineageStore.successors(defaults: defaults)
        #expect(lineage.count == 2)
        #expect(PhotoLineageStore.terminalSuccessors(
            of: retired, lineage: lineage, existing: [kept, end]) == [kept, end])
        #expect(PhotoLineageStore.terminalSuccessors(
            of: retired, lineage: lineage, existing: [retired, kept, end]).isEmpty)
        #expect(PhotoLineageStore.terminalSuccessors(of: retired, lineage: lineage, existing: []).isEmpty)
        #expect(PhotoLineageStore.terminalSuccessors(of: UUID(), lineage: lineage, existing: [kept]).isEmpty)

        let beforeFailedSave = PhotoLineageStore.record(
            [.init(retiredID: kept, successorIDs: [end])], defaults: defaults)
        PhotoLineageStore.restore(beforeFailedSave, defaults: defaults)
        #expect(PhotoLineageStore.successors(defaults: defaults) == lineage)
    }

    @Test("A hidden choice that syncs in for a retired trip is inherited by its successors; a pin is not")
    func lateHiddenChoiceFollowsLineage() async throws {
        let container = try orphanStore()
        let defaults = P06Fixture.makeDefaults()
        let retired = UUID(), first = UUID(), second = UUID(), gone = UUID()
        let ctx = ModelContext(container)
        P06Fixture.makeTrip(in: ctx, startDay: 20, endDay: 22, id: first)
        P06Fixture.makeTrip(in: ctx, startDay: 22, endDay: 24, id: second)
        let alreadyHidden = HiddenPhoto(localIdentifier: "p06-elsewhere", tripID: second)
        alreadyHidden.cloudIdentifier = "cloud-late"
        ctx.insert(alreadyHidden)
        try ctx.save()
        PhotoLineageStore.record([.init(retiredID: retired, successorIDs: [first, second]),
                                  .init(retiredID: gone, successorIDs: [UUID()])], defaults: defaults)

        let lateHidden = P06Fixture.date(day: 302)
        let late = HiddenPhoto(localIdentifier: "p06-late", tripID: retired)
        late.cloudIdentifier = "cloud-late"
        late.hiddenAt = lateHidden
        ctx.insert(late)
        ctx.insert(PinnedPhoto(localIdentifier: "p06-late-pin", tripID: retired))
        ctx.insert(HiddenPhoto(localIdentifier: "p06-ends-missing", tripID: gone))
        try ctx.save()

        let outcome = await PhotoAnnotationDeduplicator.sweepOrphans(
            modelContainer: container, now: Self.orphanBase, defaults: defaults)
        #expect(outcome.completed && outcome.deleted == 0)
        #expect(outcome.rekeyedOnto == [first])
        let hidden = try ModelContext(container).fetch(FetchDescriptor<HiddenPhoto>())
        #expect(!hidden.contains { $0.tripID == retired })
        let inherited = try #require(hidden.first { $0.tripID == first })
        #expect(inherited.cloudIdentifier == "cloud-late" && inherited.hiddenAt == lateHidden)
        #expect(hidden.filter { $0.tripID == second }.count == 1)
        // The pin and the row whose lineage leads nowhere age as orphans.
        #expect(hidden.contains { $0.tripID == gone })
        #expect(try ModelContext(container).fetch(FetchDescriptor<PinnedPhoto>()).map(\.tripID) == [retired])
        #expect(orphanMap(defaults).count == 2)

        // A second sweep inherits nothing again.
        let again = await PhotoAnnotationDeduplicator.sweepOrphans(
            modelContainer: container, now: Self.orphanBase.addingTimeInterval(3600), defaults: defaults)
        #expect(again.completed && again.rekeyedOnto.isEmpty)
        #expect(try ModelContext(container).fetch(FetchDescriptor<HiddenPhoto>()).filter { $0.tripID == first }.count == 1)
    }

    @Test("Delete All Data clears the hidden-photo lineage")
    func wipeClearsLineage() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let defaults = P06Fixture.makeDefaults()
        PhotoLineageStore.record([.init(retiredID: UUID(), successorIDs: [UUID()])], defaults: defaults)
        #expect(DataWipe.execute(container: container, defaults: defaults))
        #expect(defaults.stringArray(forKey: PhotoLineageStore.defaultsKey) == nil)
    }

    @Test("Only two known, different iCloud identities attribute the widget mirror to another account")
    func mirrorAccountAttribution() throws {
        let a = Data("account-a".utf8)
        let b = Data("account-b".utf8)
        #expect(RememberedCountriesStorage.mirrorBelongsToAnotherAccount(mirrored: a, current: b))
        #expect(!RememberedCountriesStorage.mirrorBelongsToAnotherAccount(mirrored: a, current: a))
        #expect(!RememberedCountriesStorage.mirrorBelongsToAnotherAccount(mirrored: nil, current: b))
        #expect(!RememberedCountriesStorage.mirrorBelongsToAnotherAccount(mirrored: a, current: nil))
        let defaults = P06Fixture.makeDefaults()
        RememberedCountriesStorage.writeMirrorAccount(a, to: defaults)
        #expect(defaults.data(forKey: RememberedCountriesStorage.appGroupMirrorAccountKey) == a)
        // An unavailable token keeps the last known attribution (P08RegressionTests).
        RememberedCountriesStorage.writeMirrorAccount(nil, to: defaults)
        #expect(defaults.data(forKey: RememberedCountriesStorage.appGroupMirrorAccountKey) == a)
    }
}
