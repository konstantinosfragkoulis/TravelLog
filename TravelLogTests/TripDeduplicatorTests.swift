//
//  TripDeduplicatorTests.swift
//  TravelLogTests
//
//  CloudKit-convergence sweep for `Trip`. Two devices that
//  assemble the same journey before sync settles leave one completed row
//  with zero stays. Pins: the device-local first-observed grace (a row is
//  removed only once it has been empty here for `ghostGracePeriod`), the
//  mid-sync guard (completed trips but zero stays ⇒ skip), the carry of a
//  custom name and photo annotations onto the single matching winner,
//  that open trips and populated trips are never touched, and idempotence.
//
//  `@MainActor` because the app target compiles with MainActor-by-default
//  isolation, which makes `@Model` types MainActor-isolated.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite(.serialized)
struct TripDeduplicatorTests {

    private static let day: TimeInterval = 24 * 60 * 60
    private static let base = Date(timeIntervalSinceReferenceDate: 520 * day)

    private func date(day offset: Double) -> Date {
        Self.base.addingTimeInterval(offset * Self.day)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "TripDeduplicatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @discardableResult
    private func makeTrip(
        in ctx: ModelContext, startDay: Double, endDay: Double?,
        complete: Bool = true, customName: String? = nil
    ) -> Trip {
        let trip = Trip(startDate: date(day: startDay))
        trip.endDate = endDay.map { date(day: $0) }
        trip.isComplete = complete
        trip.customName = customName
        trip.destinationSummary = "Paris"
        trip.countryCodes = "FR"
        ctx.insert(trip)
        return trip
    }

    @discardableResult
    private func makeStay(in ctx: ModelContext, day: Double, trip: Trip?) -> Stay {
        let start = date(day: day)
        let stay = Stay(
            startTime: start, endTime: start.addingTimeInterval(6 * 3600),
            centroidLatitude: 48.85, centroidLongitude: 2.35,
            h3IndexRes6: "P", pingCount: 3, distanceFromHomeKm: 2_100, pingIDs: [])
        stay.category = .destination
        stay.trip = trip
        ctx.insert(stay)
        return stay
    }

    private func trips(_ container: ModelContainer) throws -> [Trip] {
        try ModelContext(container).fetch(FetchDescriptor<Trip>())
    }

    // MARK: - Guards

    @Test("empty store is a no-op and clears the observation map")
    func emptyStore() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let defaults = makeDefaults()
        defaults.set(["stale": 1.0], forKey: TripDeduplicator.firstObservedGhostsKey)
        let outcome = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 0), defaults: defaults)
        #expect(outcome == TripDeduplicator.Outcome())
        #expect(defaults.dictionary(forKey: TripDeduplicator.firstObservedGhostsKey) == nil)
    }

    @Test("completed trips with zero stays in the whole store reads as mid-sync and is skipped")
    func midSyncStoreIsSkipped() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeTrip(in: ctx, startDay: 0, endDay: 3)
        try ctx.save()
        let defaults = makeDefaults()

        // Even a second sweep well past the grace must not delete: the
        // first never recorded an observation.
        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 0), defaults: defaults)
        let outcome = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 2), defaults: defaults)
        #expect(outcome.deleted == 0)
        #expect(try trips(container).count == 1)
        #expect(defaults.dictionary(forKey: TripDeduplicator.firstObservedGhostsKey) == nil)
    }

    // MARK: - Grace

    @Test("a ghost is observed on the first sweep and deleted only after the grace period")
    func ghostSurvivesGraceThenGoes() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let real = makeTrip(in: ctx, startDay: 0, endDay: 3)
        makeStay(in: ctx, day: 1, trip: real)
        let ghost = makeTrip(in: ctx, startDay: 0, endDay: 3)
        try ctx.save()
        let defaults = makeDefaults()

        let first = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 20), defaults: defaults)
        #expect(first.deleted == 0)
        #expect(first.observed == 1)
        #expect(try trips(container).count == 2)

        let early = await TripDeduplicator.deduplicateAll(
            modelContainer: container,
            now: date(day: 20).addingTimeInterval(TripDeduplicator.ghostGracePeriod - 1),
            defaults: defaults)
        #expect(early.deleted == 0)

        let late = await TripDeduplicator.deduplicateAll(
            modelContainer: container,
            now: date(day: 20).addingTimeInterval(TripDeduplicator.ghostGracePeriod),
            defaults: defaults)
        #expect(late.deleted == 1)
        let remaining = try trips(container)
        #expect(remaining.map(\.id) == [real.id])
        #expect(!remaining.map(\.id).contains(ghost.id))
        #expect(defaults.dictionary(forKey: TripDeduplicator.firstObservedGhostsKey) == nil)
    }

    @Test("With iCloud on, a ghost matures only after a successful import completes past its grace")
    func ghostWaitsForImportPastGraceWithSyncOn() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let real = makeTrip(in: ctx, startDay: 0, endDay: 3)
        makeStay(in: ctx, day: 1, trip: real)
        makeTrip(in: ctx, startDay: 10, endDay: 12)
        try ctx.save()
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppDelegate.iCloudSyncEnabledKey)
        let t0 = date(day: 20)
        let grace = TripDeduplicator.ghostGracePeriod
        let later = t0.addingTimeInterval(grace + 3600)

        let first = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: t0, defaults: defaults)
        #expect(first.observed == 1)
        #expect(first.deleted == 0)

        let noImport = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: later, defaults: defaults)
        #expect(noImport.deleted == 0)
        #expect(noImport.observed == 1)
        #expect(try trips(container).count == 2)

        defaults.set(t0.addingTimeInterval(3600), forKey: AppDelegate.lastSuccessfulCloudImportAtKey)
        let earlyImport = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: later, defaults: defaults)
        #expect(earlyImport.deleted == 0)
        #expect(try trips(container).count == 2)

        defaults.set(t0.addingTimeInterval(grace + 60), forKey: AppDelegate.lastSuccessfulCloudImportAtKey)
        let caughtUp = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: later, defaults: defaults)
        #expect(caughtUp.deleted == 1)
        #expect(try trips(container).map(\.id) == [real.id])
    }

    @Test("A newly observed physical UUID twin receives its own full grace")
    func staggeredTwinsHaveIndependentGrace() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let anchor = makeTrip(in: ctx, startDay: 30, endDay: 33)
        makeStay(in: ctx, day: 31, trip: anchor)
        let a = makeTrip(in: ctx, startDay: 0, endDay: 4)
        let sharedID = a.id
        try ctx.save()
        let aID = a.persistentModelID
        let defaults = makeDefaults()
        let t = date(day: 40)
        _ = await TripDeduplicator.deduplicateAll(modelContainer: container, now: t, defaults: defaults)
        let b = makeTrip(in: ctx, startDay: 0, endDay: 4)
        b.id = sharedID
        try ctx.save()
        let bID = b.persistentModelID
        #expect(aID != bID)
        let second = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: t.addingTimeInterval(25 * 3600), defaults: defaults)
        #expect(second.deleted == 1)
        let survivors = try trips(container).map(\.persistentModelID)
        #expect(!survivors.contains(aID))
        #expect(survivors.contains(bID))
        let early = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: t.addingTimeInterval(48 * 3600), defaults: defaults)
        #expect(early.deleted == 0)
        #expect(try trips(container).contains { $0.persistentModelID == bID })
        let expired = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: t.addingTimeInterval(50 * 3600), defaults: defaults)
        #expect(expired.deleted == 1)
        #expect(!(try trips(container).contains { $0.persistentModelID == bID }))
    }

    @Test("A legacy UUID observation grants fresh physical-row grace and is pruned")
    func legacyGraceIsNotInherited() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let anchor = makeTrip(in: ctx, startDay: 30, endDay: 33)
        makeStay(in: ctx, day: 31, trip: anchor)
        let ghost = makeTrip(in: ctx, startDay: 0, endDay: 4)
        try ctx.save()
        let id = ghost.persistentModelID
        let uuidKey = ghost.id.uuidString
        let defaults = makeDefaults()
        defaults.set([uuidKey: date(day: 20).timeIntervalSince1970, "orphan": 1.0],
                     forKey: TripDeduplicator.firstObservedGhostsKey)
        let outcome = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 40), defaults: defaults)
        #expect(outcome.deleted == 0)
        #expect(try trips(container).contains { $0.persistentModelID == id })
        let ledger = defaults.dictionary(forKey: TripDeduplicator.firstObservedGhostsKey)
        #expect(ledger?.count == 1)
        #expect(ledger?[uuidKey] == nil)
        #expect(ledger?["orphan"] == nil)
    }

    @Test("A favourite added after the production snapshot retains a no-winner ghost")
    func favouriteAfterSnapshotRetainsGhost() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let anchor = makeTrip(in: ctx, startDay: 30, endDay: 33)
        makeStay(in: ctx, day: 31, trip: anchor)
        let ghost = makeTrip(in: ctx, startDay: 0, endDay: 4)
        let ghostID = ghost.id
        try ctx.save()
        let rowID = ghost.persistentModelID
        let defaults = makeDefaults()
        let pinDefaults = makeDefaults()
        let pins = PinnedTripsStorage(forTesting: pinDefaults)
        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 40), defaults: defaults, pins: pins)
        TripDeduplicator.afterFavouriteSnapshotForTesting = { pins.pin(ghostID) }
        defer { TripDeduplicator.afterFavouriteSnapshotForTesting = nil }
        let outcome = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 42), defaults: defaults, pins: pins)
        #expect(outcome.deleted == 0)
        #expect(try trips(container).contains { $0.persistentModelID == rowID })
        #expect(PinnedTripsStorage(forTesting: pinDefaults).isPinned(ghostID))
    }

    @Test("A new favourite vetoes a prepared winner carry without moving annotations")
    func favouriteVetoDoesNotApplyPreparedCarry() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let winner = makeTrip(in: ctx, startDay: 0, endDay: 4)
        makeStay(in: ctx, day: 1, trip: winner)
        let ghost = makeTrip(in: ctx, startDay: 0, endDay: 4, customName: "My holiday")
        ghost.userEdited = true
        let ghostID = ghost.id
        let winnerID = winner.id
        ctx.insert(HiddenPhoto(localIdentifier: "hidden-veto", tripID: ghostID))
        ctx.insert(PinnedPhoto(localIdentifier: "pinned-veto", tripID: ghostID))
        // Force a save even when this ghost is vetoed, exposing accidental
        // preparation writes that would otherwise die with the worker context.
        makeTrip(in: ctx, startDay: 30, endDay: 33)
        try ctx.save()
        let rowID = ghost.persistentModelID
        let defaults = makeDefaults()
        let pins = PinnedTripsStorage(forTesting: makeDefaults())
        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 40), defaults: defaults, pins: pins)
        TripDeduplicator.afterFavouriteSnapshotForTesting = { pins.pin(ghostID) }
        var sawPreparedCarry = false
        TripDeduplicator.beforeFavouriteRecheckForTesting = { preparedIDs, photoCount in
            #expect(preparedIDs == [ghostID])
            #expect(photoCount == 2)
            sawPreparedCarry = true
        }
        defer {
            TripDeduplicator.afterFavouriteSnapshotForTesting = nil
            TripDeduplicator.beforeFavouriteRecheckForTesting = nil
        }
        let outcome = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 42), defaults: defaults, pins: pins)
        #expect(sawPreparedCarry)
        #expect(outcome.deleted == 1)
        #expect(outcome.carried.isEmpty)
        let fresh = ModelContext(container)
        let remaining = try fresh.fetch(FetchDescriptor<Trip>())
        #expect(remaining.contains { $0.persistentModelID == rowID })
        let retainedWinner = try #require(remaining.first { $0.id == winnerID })
        #expect(retainedWinner.customName == nil)
        #expect(!retainedWinner.userEdited)
        #expect(try fresh.fetch(FetchDescriptor<HiddenPhoto>()).map(\.tripID) == [ghostID])
        #expect(try fresh.fetch(FetchDescriptor<PinnedPhoto>()).map(\.tripID) == [ghostID])
        #expect(pins.isPinned(ghostID))
        #expect(!pins.isPinned(winnerID))
    }

    @Test("Prepared carries preserve name conflicts when ghosts share a winner",
          arguments: [false, true])
    func preparedCarriesSharingWinner(_ pinFirst: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let winner = makeTrip(in: ctx, startDay: 0, endDay: 4)
        makeStay(in: ctx, day: 1, trip: winner)
        let first = makeTrip(in: ctx, startDay: 0, endDay: 4, customName: "First holiday")
        let second = makeTrip(in: ctx, startDay: 0, endDay: 4, customName: "Second holiday")
        let firstID = first.id
        let secondID = second.id
        let winnerID = winner.id
        try ctx.save()
        let defaults = makeDefaults()
        let pins = PinnedTripsStorage(forTesting: makeDefaults())
        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 40), defaults: defaults, pins: pins)
        if pinFirst {
            TripDeduplicator.afterFavouriteSnapshotForTesting = { pins.pin(firstID) }
        }
        defer { TripDeduplicator.afterFavouriteSnapshotForTesting = nil }
        let outcome = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 42), defaults: defaults, pins: pins)
        #expect(outcome.deleted == 1)
        #expect(outcome.carried.count == 1)
        let carry = try #require(outcome.carried.first)
        #expect(carry.winnerID == winnerID)
        let remaining = try trips(container)
        let retainedWinner = try #require(remaining.first { $0.id == winnerID })
        #expect(retainedWinner.customName == (carry.ghostID == firstID ? "First holiday" : "Second holiday"))
        #expect(remaining.count == 2)
        if pinFirst {
            #expect(carry.ghostID == secondID)
            #expect(pins.isPinned(firstID))
            #expect(remaining.contains { $0.id == firstID })
        }
    }

    @Test("A pin added after deletion is removed by production post-save reconciliation")
    func pinAfterSaveIsRemoved() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let anchor = makeTrip(in: ctx, startDay: 30, endDay: 33)
        makeStay(in: ctx, day: 31, trip: anchor)
        let ghost = makeTrip(in: ctx, startDay: 0, endDay: 4)
        let ghostID = ghost.id
        try ctx.save()
        let rowID = ghost.persistentModelID
        let defaults = makeDefaults()
        let pinDefaults = makeDefaults()
        let pins = PinnedTripsStorage(forTesting: pinDefaults)
        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 40), defaults: defaults, pins: pins)
        TripDeduplicator.afterSaveForTesting = { pins.pin(ghostID) }
        defer { TripDeduplicator.afterSaveForTesting = nil }
        let outcome = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 42), defaults: defaults, pins: pins)
        #expect(outcome.deleted == 1)
        #expect(!(try trips(container).contains { $0.persistentModelID == rowID }))
        #expect(!pins.isPinned(ghostID))
        #expect(!PinnedTripsStorage(forTesting: pinDefaults).isPinned(ghostID))
    }

    @Test("Physical observation keys survive encoding and a fresh context")
    func physicalKeyRoundTrips() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let ghost = makeTrip(in: ctx, startDay: 0, endDay: 4)
        try ctx.save()
        let key = try TripDeduplicator.observationKey(for: ghost.persistentModelID)
        let data = try #require(Data(base64Encoded: String(key.dropFirst("row:".count))))
        let decoded = try JSONDecoder().decode(PersistentIdentifier.self, from: data)
        let fetched = try #require(trips(container).first)
        #expect(decoded == fetched.persistentModelID)
        #expect(try TripDeduplicator.observationKey(for: decoded) == key)
        #expect(try TripDeduplicator.observationKey(for: fetched.persistentModelID) == key)
    }

    @Test("Post-save cleanup preserves a late pin belonging to a surviving physical twin",
          arguments: [true, false], [true, false])
    func pinForSurvivingTwinIsKept(_ twinIsComplete: Bool, _ arrivesAfterSave: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let anchor = makeTrip(in: ctx, startDay: 30, endDay: 33)
        makeStay(in: ctx, day: 31, trip: anchor)
        let ghost = makeTrip(in: ctx, startDay: 0, endDay: 4)
        let ghostID = ghost.id
        try ctx.save()
        let ghostRowID = ghost.persistentModelID
        let defaults = makeDefaults()
        let pinDefaults = makeDefaults()
        let pins = PinnedTripsStorage(forTesting: pinDefaults)
        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 40), defaults: defaults, pins: pins)
        var twinRowID: PersistentIdentifier?
        let insertTwin = {
            let insertionContext = ModelContext(container)
            let twin = makeTrip(in: insertionContext, startDay: 0, endDay: 4, complete: twinIsComplete)
            twin.id = ghostID
            try insertionContext.save()
            twinRowID = twin.persistentModelID
        }
        if !arrivesAfterSave { try insertTwin() }
        TripDeduplicator.afterSaveForTesting = {
            if arrivesAfterSave {
                do { try insertTwin() } catch { Issue.record(error) }
            }
            pins.pin(ghostID)
        }
        defer { TripDeduplicator.afterSaveForTesting = nil }
        let outcome = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 42), defaults: defaults, pins: pins)
        #expect(outcome.deleted == 1)
        let remaining = try trips(container).map(\.persistentModelID)
        #expect(!remaining.contains(ghostRowID))
        #expect(remaining.contains(try #require(twinRowID)))
        #expect(PinnedTripsStorage(forTesting: pinDefaults).isPinned(ghostID))
    }

    @Test("Production reconciliation rekeys a favourite added after a winning carry saves")
    func lateFavouriteCarriesToWinner() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let winner = makeTrip(in: ctx, startDay: 0, endDay: 4)
        makeStay(in: ctx, day: 1, trip: winner)
        let winnerID = winner.id
        let ghost = makeTrip(in: ctx, startDay: 0, endDay: 4)
        let ghostID = ghost.id
        try ctx.save()
        let defaults = makeDefaults()
        let pinDefaults = makeDefaults()
        let pins = PinnedTripsStorage(forTesting: pinDefaults)
        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 40), defaults: defaults, pins: pins)
        TripDeduplicator.afterSaveForTesting = { pins.pin(ghostID) }
        defer { TripDeduplicator.afterSaveForTesting = nil }
        let outcome = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 42), defaults: defaults, pins: pins)
        #expect(outcome.deleted == 1)
        let persistedPins = PinnedTripsStorage(forTesting: pinDefaults)
        #expect(!persistedPins.isPinned(ghostID))
        #expect(persistedPins.isPinned(winnerID))
    }

    /// A saved, carried ghost whose favourite still points at it: the sweep
    /// deleted the row but its main-actor reconciliation never ran.
    private func carriedGhostFixture() async throws -> (
        container: ModelContainer, defaults: UserDefaults, pinDefaults: UserDefaults,
        ghostID: UUID, winnerID: UUID
    ) {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let winner = makeTrip(in: ctx, startDay: 0, endDay: 4)
        makeStay(in: ctx, day: 1, trip: winner)
        let ghost = makeTrip(in: ctx, startDay: 0, endDay: 4)
        try ctx.save()
        return (container, makeDefaults(), makeDefaults(), ghost.id, winner.id)
    }

    @Test("A favourite carried by a sweep that ends before reconciliation moves to the winner on the next sweep")
    func interruptedCarryRekeysOnNextSweep() async throws {
        let f = try await carriedGhostFixture()
        let pins = PinnedTripsStorage(forTesting: f.pinDefaults)
        pins.pin(f.ghostID)
        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: f.container, now: date(day: 40), defaults: f.defaults, pins: pins)
        // The worker saves the deletion, then the process ends before the
        // main-actor reconciliation runs.
        let interrupted = await TripDeduplicator.deduplicateAll(
            modelContainer: f.container, now: date(day: 42), defaults: f.defaults,
            favouriteIDs: [f.ghostID], livePins: pins)
        #expect(interrupted.carried == [.init(ghostID: f.ghostID, winnerID: f.winnerID)])
        #expect(!(try trips(f.container).contains { $0.id == f.ghostID }))

        let relaunched = PinnedTripsStorage(forTesting: f.pinDefaults)
        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: f.container, now: date(day: 43), defaults: f.defaults, pins: relaunched)
        #expect(relaunched.isPinned(f.winnerID))
        #expect(!relaunched.isPinned(f.ghostID))
    }

    @Test("A favourite that syncs in after its ghost was carried and deleted moves to the winner",
          arguments: [false, true])
    func remoteFavouriteAfterCarryRekeys(viaSyncNotification: Bool) async throws {
        let f = try await carriedGhostFixture()
        let pins = PinnedTripsStorage(forTesting: f.pinDefaults)
        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: f.container, now: date(day: 40), defaults: f.defaults, pins: pins)
        let outcome = await TripDeduplicator.deduplicateAll(
            modelContainer: f.container, now: date(day: 42), defaults: f.defaults, pins: pins)
        #expect(outcome.carried.count == 1)

        // Another device pinned the ghost before this deletion reached it;
        // its key-value write arrives here afterwards.
        PinnedTripsStorage(forTesting: f.pinDefaults).pin(f.ghostID)
        let synced = PinnedTripsStorage(forTesting: f.pinDefaults)
        #expect(synced.isPinned(f.ghostID))
        if viaSyncNotification {
            await TripDeduplicator.rekeyCarriedFavourites(
                modelContainer: f.container, defaults: f.defaults, pins: synced)
        } else {
            _ = await TripDeduplicator.deduplicateAll(
                modelContainer: f.container, now: date(day: 43), defaults: f.defaults, pins: synced)
        }
        #expect(synced.isPinned(f.winnerID))
        #expect(!synced.isPinned(f.ghostID))
    }

    @Test("A late favourite follows its winner's own later carry")
    func lateFavouriteFollowsCarryChain() async throws {
        let f = try await carriedGhostFixture()
        let pins = PinnedTripsStorage(forTesting: f.pinDefaults)
        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: f.container, now: date(day: 40), defaults: f.defaults, pins: pins)
        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: f.container, now: date(day: 42), defaults: f.defaults, pins: pins)

        // The winner's stays converge on a third twin; the winner becomes a
        // ghost carried in turn.
        let ctx = ModelContext(f.container)
        let finalTrip = makeTrip(in: ctx, startDay: 0, endDay: 4)
        let finalID = finalTrip.id
        for stay in try ctx.fetch(FetchDescriptor<Stay>()) { stay.trip = finalTrip }
        try ctx.save()
        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: f.container, now: date(day: 50), defaults: f.defaults, pins: pins)
        let second = await TripDeduplicator.deduplicateAll(
            modelContainer: f.container, now: date(day: 52), defaults: f.defaults, pins: pins)
        #expect(second.carried == [.init(ghostID: f.winnerID, winnerID: finalID)])

        PinnedTripsStorage(forTesting: f.pinDefaults).pin(f.ghostID)
        let synced = PinnedTripsStorage(forTesting: f.pinDefaults)
        await TripDeduplicator.rekeyCarriedFavourites(
            modelContainer: f.container, defaults: f.defaults, pins: synced)
        #expect(synced.pinnedIDs == [finalID])
    }

    @Test("Photo choices that sync in after their ghost was carried and deleted follow the winner")
    func lateAnnotationsFollowCarry() async throws {
        let f = try await carriedGhostFixture()
        let pins = PinnedTripsStorage(forTesting: f.pinDefaults)
        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: f.container, now: date(day: 40), defaults: f.defaults, pins: pins)
        let carry = await TripDeduplicator.deduplicateAll(
            modelContainer: f.container, now: date(day: 42), defaults: f.defaults, pins: pins)
        #expect(carry.carried == [.init(ghostID: f.ghostID, winnerID: f.winnerID)])
        #expect(!(try trips(f.container).contains { $0.id == f.ghostID }))

        // Another device hid and pinned photos in its copy of the ghost
        // before the deletion reached it; the rows sync in now. The winner
        // already has one of those photos pinned.
        let ctx = ModelContext(f.container)
        ctx.insert(HiddenPhoto(localIdentifier: "late-hidden", tripID: f.ghostID))
        ctx.insert(PinnedPhoto(localIdentifier: "late-pinned", tripID: f.ghostID))
        ctx.insert(PinnedPhoto(localIdentifier: "late-pinned", tripID: f.winnerID))
        try ctx.save()

        // Production order: ghost sweep, annotation dedup, orphan sweep.
        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: f.container, now: date(day: 43), defaults: f.defaults, pins: pins)
        #expect(await PhotoAnnotationDeduplicator.deduplicateAll(modelContainer: f.container))
        let sweep = await PhotoAnnotationDeduplicator.sweepOrphans(
            modelContainer: f.container, now: date(day: 43), defaults: f.defaults)
        #expect(sweep.completed)
        #expect(sweep.rekeyedOnto == [f.winnerID])
        #expect(f.defaults.dictionary(forKey: PhotoAnnotationDeduplicator.firstObservedOrphansKey) == nil)

        // The next pass collapses the pin the winner already had.
        #expect(await PhotoAnnotationDeduplicator.deduplicateAll(modelContainer: f.container))
        func annotationTrips() throws -> (hidden: [UUID], pinned: [UUID]) {
            let fresh = ModelContext(f.container)
            return (try fresh.fetch(FetchDescriptor<HiddenPhoto>()).map(\.tripID),
                    try fresh.fetch(FetchDescriptor<PinnedPhoto>()).map(\.tripID))
        }
        #expect(try annotationTrips().hidden == [f.winnerID])
        #expect(try annotationTrips().pinned == [f.winnerID])

        // Far past any orphan grace, nothing is lost.
        let later = await PhotoAnnotationDeduplicator.sweepOrphans(
            modelContainer: f.container, now: date(day: 80), defaults: f.defaults)
        #expect(later.completed)
        #expect(later.deleted == 0)
        #expect(try annotationTrips().hidden == [f.winnerID])
        #expect(try annotationTrips().pinned == [f.winnerID])
    }

    @Test("A late photo choice follows its winner's own later carry")
    func lateAnnotationFollowsCarryChain() async throws {
        let f = try await carriedGhostFixture()
        let pins = PinnedTripsStorage(forTesting: f.pinDefaults)
        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: f.container, now: date(day: 40), defaults: f.defaults, pins: pins)
        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: f.container, now: date(day: 42), defaults: f.defaults, pins: pins)

        let ctx = ModelContext(f.container)
        let finalTrip = makeTrip(in: ctx, startDay: 0, endDay: 4)
        let finalID = finalTrip.id
        for stay in try ctx.fetch(FetchDescriptor<Stay>()) { stay.trip = finalTrip }
        try ctx.save()
        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: f.container, now: date(day: 50), defaults: f.defaults, pins: pins)
        let second = await TripDeduplicator.deduplicateAll(
            modelContainer: f.container, now: date(day: 52), defaults: f.defaults, pins: pins)
        #expect(second.carried == [.init(ghostID: f.winnerID, winnerID: finalID)])

        let late = ModelContext(f.container)
        late.insert(HiddenPhoto(localIdentifier: "late", tripID: f.ghostID))
        try late.save()
        let sweep = await PhotoAnnotationDeduplicator.sweepOrphans(
            modelContainer: f.container, now: date(day: 53), defaults: f.defaults)
        #expect(sweep.rekeyedOnto == [finalID])
        #expect(try ModelContext(f.container).fetch(FetchDescriptor<HiddenPhoto>()).map(\.tripID) == [finalID])
    }

    @Test("a trip whose stays arrive during the grace is spared and forgotten")
    func lateStaysRescueTheRow() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let anchor = makeTrip(in: ctx, startDay: 10, endDay: 14)
        makeStay(in: ctx, day: 11, trip: anchor)
        let inFlight = makeTrip(in: ctx, startDay: 0, endDay: 3)
        try ctx.save()
        let defaults = makeDefaults()

        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 20), defaults: defaults)
        #expect(defaults.dictionary(forKey: TripDeduplicator.firstObservedGhostsKey)?.count == 1)

        makeStay(in: ctx, day: 1, trip: inFlight)
        try ctx.save()

        let later = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 25), defaults: defaults)
        #expect(later.deleted == 0)
        #expect(try trips(container).count == 2)
        #expect(defaults.dictionary(forKey: TripDeduplicator.firstObservedGhostsKey) == nil)
    }

    // MARK: - Scope

    @Test("open trips and populated trips are never touched")
    func onlyEmptyCompletedRowsQualify() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let populated = makeTrip(in: ctx, startDay: 0, endDay: 3)
        makeStay(in: ctx, day: 1, trip: populated)
        makeTrip(in: ctx, startDay: 5, endDay: nil, complete: false)   // open, empty
        try ctx.save()
        let defaults = makeDefaults()

        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 20), defaults: defaults)
        let outcome = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 22), defaults: defaults)
        #expect(outcome.deleted == 0)
        #expect(outcome.observed == 0)
        #expect(try trips(container).count == 2)
    }

    // MARK: - Carry

    @Test("a ghost's custom name and photo annotations move onto its single matching winner")
    func carryOntoWinner() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let winner = makeTrip(in: ctx, startDay: 0, endDay: 4)
        makeStay(in: ctx, day: 1, trip: winner)
        let ghost = makeTrip(in: ctx, startDay: 0, endDay: 4, customName: "Honeymoon")
        ghost.userEdited = true
        let unrelated = makeTrip(in: ctx, startDay: 30, endDay: 33)
        makeStay(in: ctx, day: 31, trip: unrelated)
        ctx.insert(HiddenPhoto(localIdentifier: "hidden-1", tripID: ghost.id))
        ctx.insert(PinnedPhoto(localIdentifier: "pinned-1", tripID: ghost.id))
        try ctx.save()
        let defaults = makeDefaults()

        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 20), defaults: defaults)
        let outcome = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 22), defaults: defaults)

        #expect(outcome.deleted == 1)
        #expect(outcome.carried == [.init(ghostID: ghost.id, winnerID: winner.id)])
        let fresh = ModelContext(container)
        let survivor = try #require(
            fresh.fetch(FetchDescriptor<Trip>()).first { $0.id == winner.id })
        #expect(survivor.customName == "Honeymoon")
        #expect(survivor.userEdited)
        let hidden = try fresh.fetch(FetchDescriptor<HiddenPhoto>())
        let pinned = try fresh.fetch(FetchDescriptor<PinnedPhoto>())
        #expect(hidden.map(\.tripID) == [winner.id])
        #expect(pinned.map(\.tripID) == [winner.id])
    }

    @Test("a winner's own custom name is never overwritten")
    func winnerNameWins() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let winner = makeTrip(in: ctx, startDay: 0, endDay: 4, customName: "Paris")
        makeStay(in: ctx, day: 1, trip: winner)
        let ghost = makeTrip(in: ctx, startDay: 0, endDay: 4)
        ghost.userEdited = true
        try ctx.save()
        let defaults = makeDefaults()

        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 20), defaults: defaults)
        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 22), defaults: defaults)
        let survivor = try #require(trips(container).first)
        #expect(survivor.customName == "Paris")
        #expect(survivor.userEdited)
    }

    @Test("with no matching winner an annotated ghost is retained for a later sweep")
    func noWinnerRetainsAnnotatedGhost() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let elsewhere = makeTrip(in: ctx, startDay: 30, endDay: 33)
        makeStay(in: ctx, day: 31, trip: elsewhere)
        let ghost = makeTrip(in: ctx, startDay: 0, endDay: 4)
        ctx.insert(PinnedPhoto(localIdentifier: "pinned-1", tripID: ghost.id))
        try ctx.save()
        let defaults = makeDefaults()

        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 40), defaults: defaults)
        let firstSeen = try #require(
            defaults.dictionary(forKey: TripDeduplicator.firstObservedGhostsKey)?[try TripDeduplicator.observationKey(for: ghost.persistentModelID)]
                as? Double)
        let outcome = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 42), defaults: defaults)
        #expect(outcome.deleted == 0)
        #expect(outcome.carried.isEmpty)
        #expect(try trips(container).contains { $0.id == ghost.id })
        let pinned = try ModelContext(container).fetch(FetchDescriptor<PinnedPhoto>())
        #expect(pinned.map(\.tripID) == [ghost.id])
        #expect(
            defaults.dictionary(forKey: TripDeduplicator.firstObservedGhostsKey)?[try TripDeduplicator.observationKey(for: ghost.persistentModelID)]
                as? Double == firstSeen)
    }

    @Test("two matching candidates make the winner ambiguous — nothing is carried")
    func ambiguousWinnerCarriesNothing() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let a = makeTrip(in: ctx, startDay: 0, endDay: 4)
        let b = makeTrip(in: ctx, startDay: 0, endDay: 4)
        let ghost = makeTrip(in: ctx, startDay: 0, endDay: 4)
        makeStay(in: ctx, day: 1, trip: a)
        makeStay(in: ctx, day: 3, trip: b)
        ctx.insert(HiddenPhoto(localIdentifier: "hidden-1", tripID: ghost.id))
        try ctx.save()
        let defaults = makeDefaults()

        #expect(TripDeduplicator.winner(for: ghost, among: [a, b]) == nil)
        #expect(TripDeduplicator.winner(for: ghost, among: [a])?.id == a.id)
        #expect(TripDeduplicator.winner(for: ghost, among: []) == nil)

        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 20), defaults: defaults)
        let outcome = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 22), defaults: defaults)
        #expect(outcome.deleted == 0)
        #expect(outcome.carried.isEmpty)
        #expect(Set(try trips(container).map(\.id)) == Set([a.id, b.id, ghost.id]))
        let hidden = try ModelContext(container).fetch(FetchDescriptor<HiddenPhoto>())
        #expect(hidden.map(\.tripID) == [ghost.id])
    }

    @Test("running the sweep twice after deletion changes nothing")
    func idempotent() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let real = makeTrip(in: ctx, startDay: 0, endDay: 3)
        makeStay(in: ctx, day: 1, trip: real)
        makeTrip(in: ctx, startDay: 0, endDay: 3)
        try ctx.save()
        let defaults = makeDefaults()

        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 20), defaults: defaults)
        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 22), defaults: defaults)
        let again = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 23), defaults: defaults)
        #expect(again == TripDeduplicator.Outcome())
        #expect(try trips(container).count == 1)
    }

    @Test("Insufficient identity evidence retains an edited ghost and its original timestamp", arguments: [
        "overlap", "boundary touch", "country conflict", "missing country", "invalid country", "non-ASCII country",
        "summary conflict", "missing summary", "unknown summary", "question summary",
        "partial unknown summary", "nil ghost end", "nil candidate end", "reversed dates",
        "custom name conflict", "same UUID", "incomplete candidate", "empty candidate"
    ])
    func insufficientIdentityRetainsGhost(_ scenario: String) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let candidate = makeTrip(in: ctx, startDay: 0, endDay: 4)
        let candidateStay = makeStay(in: ctx, day: 1, trip: candidate)
        let ghost = makeTrip(in: ctx, startDay: 0, endDay: 4, customName: "My trip")
        ghost.userEdited = true
        switch scenario {
        case "overlap": candidate.startDate = date(day: 2); candidate.endDate = date(day: 6)
        case "boundary touch": candidate.startDate = date(day: 4); candidate.endDate = date(day: 6)
        case "country conflict": candidate.countryCodes = "DE"
        case "missing country": ghost.countryCodes = ""
        case "invalid country": ghost.countryCodes = "?"; candidate.countryCodes = "?"
        case "non-ASCII country": ghost.countryCodes = "ß"; candidate.countryCodes = "SS"
        case "summary conflict": candidate.destinationSummary = "Lyon"
        case "missing summary": ghost.destinationSummary = " "
        case "unknown summary": ghost.destinationSummary = " Unknown "; candidate.destinationSummary = "unknown"
        case "question summary": ghost.destinationSummary = "?"; candidate.destinationSummary = "?"
        case "partial unknown summary": ghost.destinationSummary = "Paris, Unknown"; candidate.destinationSummary = "Paris, Unknown"
        case "nil ghost end": ghost.endDate = nil
        case "nil candidate end": candidate.endDate = nil
        case "reversed dates": ghost.endDate = date(day: -1); candidate.endDate = date(day: -1)
        case "custom name conflict": candidate.customName = "Someone else's trip"
        case "same UUID": candidate.id = ghost.id
        case "incomplete candidate": candidate.isComplete = false
        case "empty candidate":
            candidateStay.trip = nil
            candidate.userEdited = true // Keep this second ghost outside unannotated cleanup.
        default: Issue.record("Unhandled fixture")
        }
        try ctx.save()
        let defaults = makeDefaults()
        let firstSweep = date(day: 20)
        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: firstSweep, defaults: defaults)
        let outcome = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 22), defaults: defaults)
        #expect(outcome.deleted == 0)
        #expect(outcome.carried.isEmpty)
        let remaining = try trips(container)
        #expect(remaining.count == 2)
        let retained = try #require(remaining.first { $0.persistentModelID == ghost.persistentModelID })
        #expect(retained.customName == "My trip")
        #expect(retained.userEdited)
        #expect(defaults.dictionary(forKey: TripDeduplicator.firstObservedGhostsKey)?[try TripDeduplicator.observationKey(for: ghost.persistentModelID)]
            as? Double == firstSweep.timeIntervalSince1970)
    }

    @Test("Full summary identity cannot be replaced by a matching display prefix")
    func differingTailIsNotTheSameTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let candidate = makeTrip(in: ctx, startDay: 0, endDay: 4)
        makeStay(in: ctx, day: 1, trip: candidate)
        let ghost = makeTrip(in: ctx, startDay: 0, endDay: 4)
        ghost.userEdited = true
        candidate.destinationSummary = "Paris, Lyon, Nice, Bordeaux, Lille"
        ghost.destinationSummary = "Paris, Lyon, Nice, Bordeaux, Nantes"
        try ctx.save()
        #expect(TripDeduplicator.winner(for: ghost, among: [candidate]) == nil)
        let defaults = makeDefaults()
        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 20), defaults: defaults)
        let outcome = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 22), defaults: defaults)
        #expect(outcome.deleted == 0)
        #expect(try trips(container).count == 2)
    }

    @Test("Unannotated ghosts expire without a carry winner", arguments: ["no winner", "end mismatch", "ambiguous"])
    func unannotatedGhostExpiresWithoutWinner(_ scenario: String) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let candidate = makeTrip(in: ctx, startDay: scenario == "no winner" ? 30 : 0,
                                 endDay: scenario == "no winner" ? 33 : (scenario == "end mismatch" ? 5 : 4))
        makeStay(in: ctx, day: 1, trip: candidate)
        if scenario == "ambiguous" {
            let other = makeTrip(in: ctx, startDay: 0, endDay: 4)
            makeStay(in: ctx, day: 2, trip: other)
        }
        let ghost = makeTrip(in: ctx, startDay: 0, endDay: 4)
        let ghostID = ghost.id
        try ctx.save()
        let defaults = makeDefaults()
        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 40), defaults: defaults)
        let outcome = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 42), defaults: defaults)
        #expect(outcome.deleted == 1)
        #expect(outcome.carried.isEmpty)
        #expect(!((try trips(container)).contains { $0.id == ghostID }))
        #expect(defaults.dictionary(forKey: TripDeduplicator.firstObservedGhostsKey) == nil)
    }

    @Test("Each kind of user data retains a ghost without a winner", arguments: ["name", "edited", "favourite"])
    func noWinnerRetainsUserData(_ annotation: String) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let candidate = makeTrip(in: ctx, startDay: 0, endDay: 5)
        makeStay(in: ctx, day: 1, trip: candidate)
        let ghost = makeTrip(in: ctx, startDay: 0, endDay: 4,
                             customName: annotation == "name" ? "My holiday" : nil)
        ghost.userEdited = annotation == "edited"
        let ghostID = ghost.id
        let favourites: Set<UUID> = annotation == "favourite" ? [ghostID] : []
        try ctx.save()
        let defaults = makeDefaults()
        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 20), defaults: defaults, favouriteIDs: favourites)
        let outcome = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 22), defaults: defaults, favouriteIDs: favourites)
        #expect(outcome.deleted == 0)
        #expect(outcome.carried.isEmpty)
        #expect((try trips(container)).contains { $0.id == ghostID })
        #expect(defaults.dictionary(forKey: TripDeduplicator.firstObservedGhostsKey)?[try TripDeduplicator.observationKey(for: ghost.persistentModelID)]
            as? Double == date(day: 20).timeIntervalSince1970)
    }

    @Test("Only complete qualifying counterparts count toward ambiguity")
    func uniqueQualifiedCandidateWins() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let winner = makeTrip(in: ctx, startDay: 0, endDay: 4, customName: "Holiday")
        makeStay(in: ctx, day: 1, trip: winner)
        let other = makeTrip(in: ctx, startDay: 0, endDay: 4)
        makeStay(in: ctx, day: 1, trip: other)
        other.destinationSummary = "Lyon"
        let ghost = makeTrip(in: ctx, startDay: 0, endDay: 4, customName: " Holiday ")
        ghost.destinationSummary = "  PARIS \n  "
        ghost.countryCodes = " fr, DE,FR "
        winner.countryCodes = "de,FR"
        try ctx.save()
        #expect(TripDeduplicator.winner(for: ghost, among: [other, winner])?.id == winner.id)
        other.destinationSummary = "Paris"
        other.countryCodes = "FR,DE"
        #expect(TripDeduplicator.winner(for: ghost, among: [other, winner]) == nil)
    }

    @Test("Custom-name conflict cannot disambiguate two geographic counterparts")
    func mixedNamesStillAmbiguous() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let named = makeTrip(in: ctx, startDay: 0, endDay: 4, customName: "Other holiday")
        let unnamed = makeTrip(in: ctx, startDay: 0, endDay: 4)
        makeStay(in: ctx, day: 1, trip: named)
        makeStay(in: ctx, day: 1, trip: unnamed)
        let ghost = makeTrip(in: ctx, startDay: 0, endDay: 4, customName: "My holiday")
        try ctx.save()
        #expect(TripDeduplicator.winner(for: ghost, among: [named, unnamed]) == nil)
        let defaults = makeDefaults()
        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 20), defaults: defaults)
        let outcome = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 22), defaults: defaults)
        #expect(outcome.deleted == 0)
        #expect(outcome.carried.isEmpty)
        #expect(try trips(container).count == 3)
        #expect(defaults.dictionary(forKey: TripDeduplicator.firstObservedGhostsKey)?[try TripDeduplicator.observationKey(for: ghost.persistentModelID)]
            as? Double == date(day: 20).timeIntervalSince1970)
    }

    @Test("A ghost whose UUID twin is populated carries nothing to a third matching trip",
          arguments: [true, false])
    func populatedTwinKeepsItsAnnotations(twinIsComplete: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // Ghost G and populated twin P share one UUID; W is an independent
        // assembly of the same journey under its own UUID.
        let ghost = makeTrip(in: ctx, startDay: 0, endDay: 4)
        let sharedID = ghost.id
        let twin = makeTrip(in: ctx, startDay: 0, endDay: twinIsComplete ? 4 : nil,
                            complete: twinIsComplete)
        twin.id = sharedID
        makeStay(in: ctx, day: 1, trip: twin)
        let third = makeTrip(in: ctx, startDay: 0, endDay: 4)
        makeStay(in: ctx, day: 2, trip: third)
        let thirdID = third.id
        ctx.insert(HiddenPhoto(localIdentifier: "h-twin", tripID: sharedID))
        ctx.insert(PinnedPhoto(localIdentifier: "p-twin", tripID: sharedID))
        try ctx.save()
        let ghostRowID = ghost.persistentModelID
        let twinRowID = twin.persistentModelID
        let defaults = makeDefaults()
        let t = date(day: 40)
        _ = await TripDeduplicator.deduplicateAll(modelContainer: container, now: t, defaults: defaults)
        let outcome = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: t.addingTimeInterval(25 * 3600), defaults: defaults)

        #expect(outcome.deleted == 1)
        #expect(outcome.carried.isEmpty, "nothing may be carried onto W")
        let survivors = try trips(container).map(\.persistentModelID)
        #expect(!survivors.contains(ghostRowID))
        #expect(survivors.contains(twinRowID))
        let hidden = try ModelContext(container).fetch(FetchDescriptor<HiddenPhoto>())
        #expect(hidden.map(\.tripID) == [sharedID], "the twin's annotation stays keyed to its UUID")
        #expect(!hidden.contains { $0.tripID == thirdID })
        let pinned = try ModelContext(container).fetch(FetchDescriptor<PinnedPhoto>())
        #expect(pinned.map(\.tripID) == [sharedID])
        #expect(!pinned.contains { $0.tripID == thirdID })
    }

    // MARK: - A temporary home's mark

    /// Winner edited and marked, ghost edited and marked, then what the
    /// carried winner must read: the mark survives only when every edited
    /// copy carried it.
    @Test("a carried edit keeps a temporary home's mark only when every edited copy had it",
          arguments: [
            [false, false, true, true, true, true],
            [true, false, true, true, true, false],
            [true, true, true, true, true, true],
            [true, true, true, false, true, false],
            [true, true, false, false, true, true],
            [false, false, false, false, false, false],
          ])
    func carriedEditKeepsTheMarkOnlyWhenEveryEditedCopyHadIt(_ flags: [Bool]) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let winner = makeTrip(in: ctx, startDay: 0, endDay: 3)
        winner.userEdited = flags[0]
        winner.keptByTemporaryHome = flags[1]
        makeStay(in: ctx, day: 1, trip: winner)
        let ghost = makeTrip(in: ctx, startDay: 0, endDay: 3)
        ghost.userEdited = flags[2]
        ghost.keptByTemporaryHome = flags[3]
        try ctx.save()
        let winnerID = winner.id
        let defaults = makeDefaults()

        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 20), defaults: defaults)
        let late = await TripDeduplicator.deduplicateAll(
            modelContainer: container,
            now: date(day: 20).addingTimeInterval(TripDeduplicator.ghostGracePeriod),
            defaults: defaults)
        #expect(late.deleted == 1)
        let survivor = try #require(try trips(container).first)
        #expect(try trips(container).count == 1)
        #expect(survivor.id == winnerID)
        #expect(survivor.userEdited == flags[4])
        #expect(survivor.keptByTemporaryHome == flags[5])
    }

    // MARK: - Trips the photo-ping dedup empties

    /// A second device's parallel photo graph wins every ping of a named trip:
    /// with the identical journey there, the ping dedup keeps that trip as an
    /// empty row and the ghost sweep carries its name and hides onto it;
    /// without one, the trip keeps its stay and ping and no sweep deletes it.
    @Test("a named trip the photo-ping dedup would empty is carried onto its twin journey or kept whole",
          arguments: [true, false])
    func pingDedupEmptiedNamedTripIsCarriedOrKept(hasWinner: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        func photoPing(_ time: Date) -> LocationPing {
            LocationPing(timestamp: time, latitude: 48.85, longitude: 2.35,
                         horizontalAccuracy: 10, h3IndexRes6: "861f8d4ffffffff", source: .photoImport)
        }
        let kept = photoPing(date(day: 1))
        let duplicate = photoPing(date(day: 1).addingTimeInterval(20))
        ctx.insert(kept)
        ctx.insert(duplicate)
        let winner = makeTrip(in: ctx, startDay: hasWinner ? 0 : 10, endDay: hasWinner ? 3 : 13)
        let winnerStay = makeStay(in: ctx, day: 1, trip: winner)
        // Without a counterpart no trip holds the keeper: one holding every
        // fix that duplicates the emptied trip's is a counterpart too.
        winnerStay.pingIDs = hasWinner ? [kept.id] : []
        winnerStay.pingCount = 1
        let named = makeTrip(in: ctx, startDay: 0, endDay: 3, customName: "Paris with friends")
        let namedStay = makeStay(in: ctx, day: 1, trip: named)
        namedStay.pingIDs = [duplicate.id]
        namedStay.pingCount = 1
        ctx.insert(HiddenPhoto(localIdentifier: "hidden-ping", tripID: named.id))
        try ctx.save()
        let namedID = named.id
        let winnerID = winner.id

        let defaults = makeDefaults()
        await PhotoImportPingDeduplicator.deduplicateAll(
            modelContainer: container, bypassSingleFlightForTesting: true, defaults: defaults)
        let emptied = try #require(try trips(container).first { $0.id == namedID })
        #expect((emptied.stays ?? []).map(\.pingIDs) == (hasWinner ? [] : [[duplicate.id]]))
        #expect(emptied.customName == "Paris with friends")
        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 20), defaults: defaults)
        let late = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 22), defaults: defaults)
        let later = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 24), defaults: defaults)

        let fresh = ModelContext(container)
        let remaining = try fresh.fetch(FetchDescriptor<Trip>())
        let hidden = try fresh.fetch(FetchDescriptor<HiddenPhoto>())
        let survivor = try #require(remaining.first { $0.id == winnerID })
        if hasWinner {
            #expect(late.deleted == 1)
            #expect(late.carried == [.init(ghostID: namedID, winnerID: winnerID)])
            #expect(remaining.count == 1)
            #expect(survivor.customName == "Paris with friends")
            #expect(hidden.map(\.tripID) == [winnerID])
        } else {
            #expect(late.deleted == 0 && later.deleted == 0)
            #expect(remaining.count == 2)
            #expect(remaining.contains { $0.id == namedID && $0.customName == "Paris with friends" })
            #expect(survivor.customName == nil)
            #expect(hidden.map(\.tripID) == [namedID])
        }
        #expect(later.deleted == 0)
    }

    /// A trip owned only through a favourite or a hidden or pinned photo,
    /// with no name or edit, whose pings the ping dedup finds duplicated:
    /// with an identical journey to carry it to, it is emptied and the ghost
    /// sweep carries the choice there (logging the carry for late arrivals);
    /// without one it keeps its stay and ping, so its photos still show.
    @Test("a favourite or photo-choice trip the photo-ping dedup would empty is carried or kept whole",
          arguments: ["favourite", "hidden", "pinned"], [true, false])
    func pingDedupEmptiedChoiceTripIsCarriedOrKept(choice: String, hasWinner: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        func photoPing(_ time: Date) -> LocationPing {
            LocationPing(timestamp: time, latitude: 44.3, longitude: 12.9,
                         horizontalAccuracy: 10, h3IndexRes6: "861f8d4ffffffff", source: .photoImport)
        }
        let kept = photoPing(date(day: 1))
        let duplicate = photoPing(date(day: 1).addingTimeInterval(20))
        ctx.insert(kept)
        ctx.insert(duplicate)
        let winner = makeTrip(in: ctx, startDay: hasWinner ? 0 : 10, endDay: hasWinner ? 3 : 13)
        let winnerStay = makeStay(in: ctx, day: 1, trip: winner)
        // Without a counterpart no trip holds the keeper: one holding every
        // fix that duplicates the emptied trip's is a counterpart too.
        winnerStay.pingIDs = hasWinner ? [kept.id] : []
        winnerStay.pingCount = 1
        let owned = makeTrip(in: ctx, startDay: 0, endDay: 3)
        let ownedStay = makeStay(in: ctx, day: 1, trip: owned)
        ownedStay.pingIDs = [duplicate.id]
        ownedStay.pingCount = 1
        let ownedID = owned.id
        let winnerID = winner.id
        switch choice {
        case "hidden": ctx.insert(HiddenPhoto(localIdentifier: "owned-photo", tripID: ownedID))
        case "pinned": ctx.insert(PinnedPhoto(localIdentifier: "owned-photo", tripID: ownedID))
        default: break
        }
        try ctx.save()
        let pins = PinnedTripsStorage(forTesting: makeDefaults())
        if choice == "favourite" { pins.pin(ownedID) }

        let defaults = makeDefaults()
        await PhotoImportPingDeduplicator.deduplicateAll(
            modelContainer: container, bypassSingleFlightForTesting: true, defaults: defaults)
        let emptied = try #require(try trips(container).first { $0.id == ownedID })
        #expect((emptied.stays ?? []).map(\.pingIDs) == (hasWinner ? [] : [[duplicate.id]]))
        #expect(emptied.startDate == date(day: 0) && emptied.endDate == date(day: 3))
        let pingIDs = try ModelContext(container).fetch(FetchDescriptor<LocationPing>()).map(\.id)
        #expect(Set(pingIDs) == (hasWinner ? [kept.id] : [kept.id, duplicate.id]))

        _ = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 20), defaults: defaults, pins: pins)
        let late = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 22), defaults: defaults, pins: pins)
        let later = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: date(day: 24), defaults: defaults, pins: pins)

        let fresh = ModelContext(container)
        let remaining = try fresh.fetch(FetchDescriptor<Trip>())
        let hidden = try fresh.fetch(FetchDescriptor<HiddenPhoto>()).map(\.tripID)
        let pinned = try fresh.fetch(FetchDescriptor<PinnedPhoto>()).map(\.tripID)
        let holder = hasWinner ? winnerID : ownedID
        if hasWinner {
            #expect(late.deleted == 1)
            #expect(late.carried == [.init(ghostID: ownedID, winnerID: winnerID)])
            #expect(remaining.map(\.id) == [winnerID])
            #expect(TripDeduplicator.carriedWinners(defaults: defaults)[ownedID] == winnerID)
        } else {
            #expect(late.deleted == 0)
            #expect(Set(remaining.map(\.id)) == [winnerID, ownedID])
        }
        #expect(later.deleted == 0)
        #expect(hidden == (choice == "hidden" ? [holder] : []))
        #expect(pinned == (choice == "pinned" ? [holder] : []))
        #expect(pins.pinnedIDs == (choice == "favourite" ? [holder] : []))
    }
}
