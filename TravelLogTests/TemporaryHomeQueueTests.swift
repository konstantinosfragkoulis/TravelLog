//
//  TemporaryHomeQueueTests.swift
//  TravelLogTests
//
//  The coverage reconciliation queue's third kind. A temporary-home edit is
//  queued before its save and dropped only when its reconciliation commits;
//  the drain runs it after Homes and routine places, and first queues the
//  work a removed temporary home's evidence shows. These extend
//  `CoverageReconciliationTests` so they share its serialization: the drain
//  is single-flight through one static flag.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
private final class TemporaryHomeDrainLog {
    var events: [String] = []
}

extension CoverageReconciliationTests {

    private func temporaryHomeDefaults() throws -> (UserDefaults, String) {
        let suite = "TemporaryHomeQueueTests-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    /// Stages that log each call and answer from the given outcomes. A row
    /// with no outcome fails, so its entry stays owed.
    private func temporaryHomeStages(
        _ log: TemporaryHomeDrainLog,
        coverage: [UUID: TripClassifier.CoverageReconciliationOutcome] = [:],
        temporary: [UUID: TripClassifier.TemporaryHomeReconciliationOutcome] = [:]
    ) -> CoverageReconciliationQueue.Stages {
        CoverageReconciliationQueue.Stages(
            applyHome: { id, onSettled in
                log.events.append("home")
                let outcome = coverage[id] ?? .failed
                if outcome.isSettled { onSettled() }
                return outcome
            },
            applyRoutinePlace: { id, onSettled in
                log.events.append("routine")
                let outcome = coverage[id] ?? .failed
                if outcome.isSettled { onSettled() }
                return outcome
            },
            applyTemporaryHome: { id, onSettled in
                log.events.append("temporary")
                let outcome = temporary[id] ?? .failed
                if outcome.isSettled { onSettled() }
                return outcome
            },
            generateLocalizedTitles: { log.events.append("titles") },
            publish: { homes, routinePlaces in
                log.events.append("publish \(homes) \(routinePlaces)")
            },
            publishTemporaryHomes: { log.events.append("publish temporary") },
            heal: { log.events.append("heal") },
            isPersistentStore: { true })
    }

    @Test("a staged temporary-home edit is stored under temporaryHome|<id> and reads back as that kind")
    func temporaryHomeEntryIsStoredUnderItsOwnKey() throws {
        let (defaults, suite) = try temporaryHomeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()

        let staged = CoverageReconciliationQueue.stage(.temporaryHome, id: id, defaults: defaults)
        #expect(staged.superseded == nil)
        let stored = try #require(defaults.dictionary(
            forKey: CoverageReconciliationQueue.pendingKey) as? [String: String])
        #expect(stored == ["temporaryHome|\(id.uuidString)": staged.entry.token.uuidString])
        #expect(CoverageReconciliationQueue.pending(defaults: defaults) == [staged.entry])
        #expect(staged.entry.kind == .temporaryHome)

        // The same id as a Home is a different slot.
        let home = CoverageReconciliationQueue.enqueue(.home, id: id, defaults: defaults)
        #expect(CoverageReconciliationQueue.pending(defaults: defaults) == [home, staged.entry])
    }

    @Test("withdrawing a failed temporary-home save puts back the earlier edit's owed reconciliation")
    func temporaryHomeWithdrawalRestoresSupersededToken() throws {
        let (defaults, suite) = try temporaryHomeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()

        // Nothing superseded: withdrawal leaves no entry.
        let lone = CoverageReconciliationQueue.stage(.temporaryHome, id: id, defaults: defaults)
        CoverageReconciliationQueue.withdraw(lone, defaults: defaults)
        #expect(defaults.object(forKey: CoverageReconciliationQueue.pendingKey) == nil)

        // An earlier committed edit still owes its reconciliation after a later save fails.
        let earlier = CoverageReconciliationQueue.enqueue(.temporaryHome, id: id, defaults: defaults)
        let failed = CoverageReconciliationQueue.stage(.temporaryHome, id: id, defaults: defaults)
        #expect(failed.superseded == earlier.token.uuidString)
        CoverageReconciliationQueue.withdraw(failed, defaults: defaults)
        #expect(CoverageReconciliationQueue.pending(defaults: defaults) == [earlier])
    }

    @Test("completing a temporary-home entry drops it only while its token is still the current one")
    func temporaryHomeCompletionNeedsTheCurrentToken() throws {
        let (defaults, suite) = try temporaryHomeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let older = CoverageReconciliationQueue.enqueue(.temporaryHome, id: id, defaults: defaults)
        let newer = CoverageReconciliationQueue.enqueue(.temporaryHome, id: id, defaults: defaults)

        CoverageReconciliationQueue.complete(older, defaults: defaults)
        #expect(CoverageReconciliationQueue.pending(defaults: defaults) == [newer])
        CoverageReconciliationQueue.complete(newer, defaults: defaults)
        #expect(defaults.object(forKey: CoverageReconciliationQueue.pendingKey) == nil)
    }

    @Test("the drain reconciles Homes, then routine places, then temporary homes, and follows with titles, publication and healing")
    func drainRunsTemporaryHomesLast() async throws {
        let (defaults, suite) = try temporaryHomeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = UUID(), place = UUID(), temporary = UUID()
        // Queued in the opposite order.
        CoverageReconciliationQueue.enqueue(.temporaryHome, id: temporary, defaults: defaults)
        CoverageReconciliationQueue.enqueue(.routinePlace, id: place, defaults: defaults)
        CoverageReconciliationQueue.enqueue(.home, id: home, defaults: defaults)
        #expect(CoverageReconciliationQueue.pending(defaults: defaults).map(\.kind)
                == [.home, .routinePlace, .temporaryHome])
        let log = TemporaryHomeDrainLog()

        let drained = await CoverageReconciliationQueue.drainIfNeeded(
            defaults: defaults,
            stages: temporaryHomeStages(
                log,
                coverage: [home: .committed(resetCount: 1), place: .committed(resetCount: 1)],
                temporary: [temporary: .committed(
                    stamped: 2, freed: 0, rebuiltTrips: 1, protectedTrips: 0)]))

        #expect(drained)
        #expect(log.events == ["home", "routine", "temporary", "titles",
                               "publish true true", "publish temporary", "heal"])
        #expect(defaults.object(forKey: CoverageReconciliationQueue.pendingKey) == nil)
    }

    @Test("a committed temporary-home reconciliation alone runs titles, its own publication and healing, and a failed or cancelled one stays queued")
    func drainKeepsUnsettledTemporaryHomes() async throws {
        let (defaults, suite) = try temporaryHomeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let committed = UUID(), failed = UUID(), cancelled = UUID()
        CoverageReconciliationQueue.enqueue(.temporaryHome, id: committed, defaults: defaults)
        let failedEntry = CoverageReconciliationQueue.enqueue(
            .temporaryHome, id: failed, defaults: defaults)
        let cancelledEntry = CoverageReconciliationQueue.enqueue(
            .temporaryHome, id: cancelled, defaults: defaults)
        let log = TemporaryHomeDrainLog()

        let drained = await CoverageReconciliationQueue.drainIfNeeded(
            defaults: defaults,
            stages: temporaryHomeStages(log, temporary: [
                committed: .committed(stamped: 0, freed: 3, rebuiltTrips: 0, protectedTrips: 0),
                failed: .failed, cancelled: .cancelled,
            ]))

        #expect(!drained)
        #expect(log.events == ["temporary", "temporary", "temporary",
                               "titles", "publish temporary", "heal"])
        let owed = CoverageReconciliationQueue.pending(defaults: defaults)
        #expect(Set(owed.map(\.id)) == [failed, cancelled])
        #expect(owed.first { $0.id == failed } == failedEntry)
        #expect(owed.first { $0.id == cancelled } == cancelledEntry)
    }

    @Test("stages that never wired a temporary-home reconciliation leave its entry owed")
    func unwiredTemporaryHomeStageKeepsTheEntry() async throws {
        let (defaults, suite) = try temporaryHomeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let entry = CoverageReconciliationQueue.enqueue(
            .temporaryHome, id: UUID(), defaults: defaults)
        let log = TemporaryHomeDrainLog()
        let stages = CoverageReconciliationQueue.Stages(
            applyHome: { _, _ in .failed },
            applyRoutinePlace: { _, _ in .failed },
            generateLocalizedTitles: { log.events.append("titles") },
            publish: { _, _ in log.events.append("publish") },
            heal: { log.events.append("heal") },
            isPersistentStore: { true })

        #expect(await CoverageReconciliationQueue.drainIfNeeded(
            defaults: defaults, stages: stages) == false)
        #expect(log.events.isEmpty)
        #expect(CoverageReconciliationQueue.pending(defaults: defaults) == [entry])
    }

    @Test("an entry of a kind this build does not know is left in place untouched by reads and by a drain")
    func unknownKindIsLeftInPlace() async throws {
        let (defaults, suite) = try temporaryHomeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let unknownKey = "futureKind|\(UUID().uuidString)"
        let unknownToken = UUID().uuidString
        defaults.set([unknownKey: unknownToken], forKey: CoverageReconciliationQueue.pendingKey)
        let temporary = UUID()
        CoverageReconciliationQueue.enqueue(.temporaryHome, id: temporary, defaults: defaults)
        #expect(CoverageReconciliationQueue.pending(defaults: defaults).map(\.id) == [temporary])
        let log = TemporaryHomeDrainLog()

        let drained = await CoverageReconciliationQueue.drainIfNeeded(
            defaults: defaults,
            stages: temporaryHomeStages(log, temporary: [temporary: .committed(
                stamped: 1, freed: 0, rebuiltTrips: 0, protectedTrips: 0)]))

        #expect(drained)
        #expect(log.events == ["temporary", "titles", "publish temporary", "heal"])
        #expect(CoverageReconciliationQueue.pending(defaults: defaults).isEmpty)
        let stored = try #require(defaults.dictionary(
            forKey: CoverageReconciliationQueue.pendingKey) as? [String: String])
        #expect(stored == [unknownKey: unknownToken])
    }

    @Test("the drain runs the classifier's real temporary-home unit and settles its entry when the unit commits")
    func drainSettlesThroughTheRealUnit() async throws {
        let (defaults, suite) = try temporaryHomeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        ctx.insert(Home(label: "Athens", latitude: 38, longitude: 23.8, radiusKm: 25,
                        startedAt: Date(timeIntervalSinceReferenceDate: 0 - 3_628_800)))
        // A home stay a temporary home stamped, since removed: the queued
        // entry's row is a tombstone, and the unit frees what it had claimed.
        let start = Date(timeIntervalSinceReferenceDate: 100 * 86_400 - 3_628_800)
        let removed = TemporaryHome(
            label: "Erasmus", latitude: 50.8798, longitude: 4.3624,
            startedAt: start.addingTimeInterval(-30 * 86_400))
        removed.removedAt = start.addingTimeInterval(10 * 86_400)
        ctx.insert(removed)
        let removedID = removed.id
        let orphan = Stay(
            startTime: start, endTime: start.addingTimeInterval(6 * 3600),
            centroidLatitude: 50.8798, centroidLongitude: 4.3624,
            h3IndexRes6: "T", pingCount: 2, distanceFromHomeKm: 0, pingIDs: [])
        orphan.category = .home
        orphan.temporaryHomeID = removedID
        ctx.insert(orphan)
        try ctx.save()
        let orphanID = orphan.id
        CoverageReconciliationQueue.enqueue(.temporaryHome, id: removedID, defaults: defaults)
        let classifier = TripClassifier(modelContainer: container)
        let log = TemporaryHomeDrainLog()
        var stages = temporaryHomeStages(log)
        stages.applyTemporaryHome = { id, onSettled in
            log.events.append("temporary")
            // The core, not the entry point: a commit there starts the model lane.
            let outcome = await classifier.applyTemporaryHomeChangeCore(
                temporaryHomeID: id, pinnedTripIDs: [])
            if outcome.isSettled { onSettled() }
            return outcome
        }

        // A failed save keeps the entry and runs no follow-up.
        await classifier.failNextReconciliationSaveForTesting()
        #expect(await CoverageReconciliationQueue.drainIfNeeded(
            defaults: defaults, stages: stages) == false)
        #expect(log.events == ["temporary"])
        #expect(CoverageReconciliationQueue.pending(defaults: defaults).map(\.id) == [removedID])

        // The retry commits: the stay is freed and the entry is gone.
        #expect(await CoverageReconciliationQueue.drainIfNeeded(
            defaults: defaults, stages: stages))
        #expect(log.events == ["temporary", "temporary", "titles", "publish temporary", "heal"])
        #expect(defaults.object(forKey: CoverageReconciliationQueue.pendingKey) == nil)
        let fresh = ModelContext(container)
        let freed = try #require(try fresh.fetch(FetchDescriptor<Stay>(
            predicate: #Predicate { $0.id == orphanID })).first)
        #expect(freed.category == .unclassified)
        #expect(freed.temporaryHomeID == nil)
        let tombstone = try #require(try fresh.fetch(FetchDescriptor<TemporaryHome>()).first)
        #expect(tombstone.id == removedID && tombstone.removedAt != nil)
    }

    // MARK: - Removal discovery

    /// A store with a real Home and one removed temporary home at Brussels.
    private func removalStore() throws -> (ModelContainer, removedID: UUID) {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        ctx.insert(Home(label: "Athens", latitude: 38, longitude: 23.8, radiusKm: 25,
                        startedAt: Date(timeIntervalSinceReferenceDate: 0 - 3_628_800)))
        let removed = TemporaryHome(
            label: "Erasmus", latitude: 50.8798, longitude: 4.3624,
            startedAt: Date(timeIntervalSinceReferenceDate: 70 * 86_400 - 3_628_800))
        removed.removedAt = Date(timeIntervalSinceReferenceDate: 200 * 86_400 - 3_628_800)
        ctx.insert(removed)
        try ctx.save()
        return (container, removed.id)
    }

    /// A `.home` stay stamped by `temporaryHomeID`, on day `day`.
    @discardableResult
    private func insertRemovalStay(
        in container: ModelContainer, temporaryHomeID: UUID, day: Double,
        latitude: Double = 50.8798, longitude: Double = 4.3624, id: UUID? = nil
    ) throws -> Stay {
        let ctx = ModelContext(container)
        let start = Date(timeIntervalSinceReferenceDate: day * 86_400 - 3_628_800)
        let stay = Stay(
            startTime: start, endTime: start.addingTimeInterval(6 * 3600),
            centroidLatitude: latitude, centroidLongitude: longitude,
            h3IndexRes6: "T", pingCount: 2, distanceFromHomeKm: 0, pingIDs: [])
        if let id { stay.id = id }
        stay.category = .home
        stay.temporaryHomeID = temporaryHomeID
        ctx.insert(stay)
        try ctx.save()
        return stay
    }

    /// Stages whose temporary-home unit commits without touching the store
    /// and whose removal evidence is read from `container`.
    private func removalStages(
        _ log: TemporaryHomeDrainLog, container: ModelContainer
    ) -> CoverageReconciliationQueue.Stages {
        var stages = temporaryHomeStages(log)
        stages.applyTemporaryHome = { _, onSettled in
            log.events.append("temporary")
            onSettled()
            return .committed(stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 0)
        }
        stages.removalEvidence = {
            try? CoverageReconciliationQueue.removalEvidence(in: ModelContext(container))
        }
        return stages
    }

    @Test("a removed temporary home seen for the first time is reconciled once; unchanged evidence with a fresh hint queues nothing")
    func removalDiscoveryStagesOnFirstSightOnly() async throws {
        let (defaults, suite) = try temporaryHomeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (container, removedID) = try removalStore()
        try insertRemovalStay(in: container, temporaryHomeID: removedID, day: 100)
        let log = TemporaryHomeDrainLog()
        let stages = removalStages(log, container: container)

        #expect(await CoverageReconciliationQueue.drainIfNeeded(defaults: defaults, stages: stages))
        #expect(log.events == ["temporary", "titles", "publish temporary", "heal"])
        #expect(defaults.object(forKey: CoverageReconciliationQueue.pendingKey) == nil)
        let evidence = try #require(try CoverageReconciliationQueue.removalEvidence(
            in: ModelContext(container))[removedID])
        #expect(!evidence.isEmpty)
        let hint = try #require(CoverageReconciliationQueue.removalHints(defaults: defaults)[removedID])
        #expect(hint.digest == evidence.digest)

        log.events = []
        #expect(await CoverageReconciliationQueue.drainIfNeeded(defaults: defaults, stages: stages))
        #expect(log.events.isEmpty)
        #expect(defaults.object(forKey: CoverageReconciliationQueue.pendingKey) == nil)
    }

    @Test("a late physical twin of a stamped stay, the same UUID at another place, changes the evidence and is reconciled again")
    func removalDiscoveryRestagesForALatePhysicalTwin() async throws {
        let (defaults, suite) = try temporaryHomeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (container, removedID) = try removalStore()
        let first = try insertRemovalStay(
            in: container, temporaryHomeID: removedID, day: 100, latitude: 38, longitude: 23.8)
        let log = TemporaryHomeDrainLog()
        let stages = removalStages(log, container: container)
        #expect(await CoverageReconciliationQueue.drainIfNeeded(defaults: defaults, stages: stages))
        let settled = try #require(CoverageReconciliationQueue.removalHints(defaults: defaults)[removedID])

        // The same stay as another device stamped it, at Brussels.
        try insertRemovalStay(in: container, temporaryHomeID: removedID, day: 100, id: first.id)
        log.events = []
        #expect(await CoverageReconciliationQueue.drainIfNeeded(defaults: defaults, stages: stages))
        #expect(log.events.first == "temporary")
        let after = try #require(CoverageReconciliationQueue.removalHints(defaults: defaults)[removedID])
        #expect(after.digest != settled.digest)
    }

    @Test("a correction keyed to a removed temporary home is work on its own: it arrives with no stay and is reconciled")
    func removalDiscoveryStagesForCorrectionOnlyEvidence() async throws {
        let (defaults, suite) = try temporaryHomeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (container, removedID) = try removalStore()
        let log = TemporaryHomeDrainLog()
        let stages = removalStages(log, container: container)
        // First sight with nothing left on this device settles an empty hint.
        #expect(await CoverageReconciliationQueue.drainIfNeeded(defaults: defaults, stages: stages))
        #expect(log.events.first == "temporary")
        #expect(CoverageReconciliationQueue.removalHints(defaults: defaults)[removedID] != nil)

        let ctx = ModelContext(container)
        ctx.insert(HomeAreaOverride(
            kind: .include, centerLatitude: 51.0495, centerLongitude: 5.2294,
            radiusKm: 1, homeID: removedID))
        try ctx.save()
        log.events = []
        #expect(await CoverageReconciliationQueue.drainIfNeeded(defaults: defaults, stages: stages))
        #expect(log.events.first == "temporary")
    }

    @Test("evidence that has not changed for over a day is reconciled again; nothing left on the device is not")
    func removalDiscoveryRestagesStaleEvidence() async throws {
        let (defaults, suite) = try temporaryHomeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (container, removedID) = try removalStore()
        let (emptyContainer, emptyID) = try removalStore()
        try insertRemovalStay(in: container, temporaryHomeID: removedID, day: 100)
        let dayAndAnHourAgo = Date.now.addingTimeInterval(-25 * 3600)
        let log = TemporaryHomeDrainLog()

        // Recorded over a day ago, unchanged since.
        CoverageReconciliationQueue.recordRemovalHints(
            try CoverageReconciliationQueue.removalEvidence(in: ModelContext(container)),
            at: dayAndAnHourAgo, defaults: defaults)
        #expect(await CoverageReconciliationQueue.drainIfNeeded(
            defaults: defaults, stages: removalStages(log, container: container)))
        #expect(log.events.first == "temporary")
        let renewed = try #require(CoverageReconciliationQueue.removalHints(defaults: defaults)[removedID])
        #expect(renewed.at > dayAndAnHourAgo)

        // The same age with no evidence queues nothing.
        let (emptyDefaults, emptySuite) = try temporaryHomeDefaults()
        defer { emptyDefaults.removePersistentDomain(forName: emptySuite) }
        CoverageReconciliationQueue.recordRemovalHints(
            try CoverageReconciliationQueue.removalEvidence(in: ModelContext(emptyContainer)),
            at: dayAndAnHourAgo, defaults: emptyDefaults)
        log.events = []
        #expect(await CoverageReconciliationQueue.drainIfNeeded(
            defaults: emptyDefaults, stages: removalStages(log, container: emptyContainer)))
        #expect(log.events.isEmpty)
        #expect(CoverageReconciliationQueue.removalHints(defaults: emptyDefaults)[emptyID]?.at
            == dayAndAnHourAgo)
    }

    @Test("a failed evidence read queues nothing, records nothing and reports the drain unfinished")
    func removalDiscoveryFailedReadChangesNothing() async throws {
        let (defaults, suite) = try temporaryHomeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = TemporaryHomeDrainLog()
        var stages = temporaryHomeStages(log)
        stages.removalEvidence = { nil }

        #expect(await CoverageReconciliationQueue.drainIfNeeded(
            defaults: defaults, stages: stages) == false)
        #expect(log.events.isEmpty)
        #expect(defaults.object(forKey: CoverageReconciliationQueue.pendingKey) == nil)
        #expect(defaults.object(forKey: CoverageReconciliationQueue.removalHintsKey) == nil)
    }

    @Test("a store with no removed temporary home queues nothing and writes no key, live temporary homes and their stays included")
    func removalDiscoveryWithoutRemovalsIsInert() async throws {
        let (defaults, suite) = try temporaryHomeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let live = TemporaryHome(
            label: "Erasmus", latitude: 50.8798, longitude: 4.3624,
            startedAt: Date(timeIntervalSinceReferenceDate: 70 * 86_400 - 3_628_800))
        ctx.insert(live)
        try ctx.save()
        try insertRemovalStay(in: container, temporaryHomeID: live.id, day: 100)
        let log = TemporaryHomeDrainLog()

        #expect(try CoverageReconciliationQueue.removalEvidence(in: ModelContext(container)).isEmpty)
        #expect(await CoverageReconciliationQueue.drainIfNeeded(
            defaults: defaults, stages: removalStages(log, container: container)))
        #expect(log.events.isEmpty)
        #expect(defaults.object(forKey: CoverageReconciliationQueue.pendingKey) == nil)
        #expect(defaults.object(forKey: CoverageReconciliationQueue.removalHintsKey) == nil)
    }

    @Test("the in-memory fallback store reads no removal evidence and queues nothing")
    func removalDiscoverySkipsTheFallbackStore() async throws {
        let (defaults, suite) = try temporaryHomeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (container, removedID) = try removalStore()
        try insertRemovalStay(in: container, temporaryHomeID: removedID, day: 100)
        let log = TemporaryHomeDrainLog()
        var stages = removalStages(log, container: container)
        stages.isPersistentStore = { false }

        #expect(await CoverageReconciliationQueue.drainIfNeeded(defaults: defaults, stages: stages))
        #expect(log.events.isEmpty)
        #expect(defaults.object(forKey: CoverageReconciliationQueue.pendingKey) == nil)
        #expect(defaults.object(forKey: CoverageReconciliationQueue.removalHintsKey) == nil)
    }

    // MARK: - Status

    @Test("a temporary home's status is nil when nothing is owed, updating while it is owed, waiting after a deferring unit and failed after a failing one, updating again for a new edit, a cancelled unit or a unit now running, and gone with its record once the entry settles")
    func temporaryHomeStatusFollowsItsLastUnit() async throws {
        let (defaults, suite) = try temporaryHomeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        typealias Outcome = TripClassifier.TemporaryHomeReconciliationOutcome
        func status() -> CoverageReconciliationQueue.TemporaryHomeStatus? {
            CoverageReconciliationQueue.temporaryHomeStatus(id: id, defaults: defaults)
        }
        let log = TemporaryHomeDrainLog()
        var seenWhileRunning: [CoverageReconciliationQueue.TemporaryHomeStatus?] = []
        func drain(_ outcome: Outcome) async {
            log.events = []
            var stages = temporaryHomeStages(log, temporary: [id: outcome])
            let apply = stages.applyTemporaryHome
            stages.applyTemporaryHome = { id, onSettled in
                seenWhileRunning.append(status())
                return await apply(id, onSettled)
            }
            stages.publishTemporaryHomeStatus = { log.events.append("status") }
            await CoverageReconciliationQueue.drainIfNeeded(defaults: defaults, stages: stages)
        }
        #expect(status() == nil)
        CoverageReconciliationQueue.enqueue(.temporaryHome, id: id, defaults: defaults)
        #expect(status() == .updating)

        await drain(.failed)
        #expect(status() == .failed)
        #expect(log.events == ["temporary", "status"])
        #expect(CoverageReconciliationQueue.pending(defaults: defaults).map(\.id) == [id])

        // A failed one reads as updating while its next unit runs.
        await drain(.deferred(stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 0))
        #expect(seenWhileRunning.last == .updating)
        #expect(status() == .waiting)
        // The committed deferral's own publication carries the status.
        #expect(log.events == ["temporary", "titles", "publish temporary", "heal"])

        await drain(.cancelled)
        #expect(status() == .updating)
        #expect(log.events == ["temporary", "status"])

        await drain(.failed)
        #expect(status() == .failed)
        // A new edit is a new entry: its unit has not run.
        CoverageReconciliationQueue.enqueue(.temporaryHome, id: id, defaults: defaults)
        #expect(status() == .updating)

        await drain(.failed)
        #expect(status() == .failed)
        await drain(.committed(stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 0))
        #expect(status() == nil)
        #expect(CoverageReconciliationQueue.pending(defaults: defaults).isEmpty)
        #expect(defaults.object(forKey: CoverageReconciliationQueue.temporaryHomeStatusKey) == nil)
    }

    @Test("the save's own run records its outcome as the drain does, only while its entry is still the current one, and completing or withdrawing the entry drops the record")
    func saveRunRecordsItsOutcome() throws {
        let (defaults, suite) = try temporaryHomeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        func status() -> CoverageReconciliationQueue.TemporaryHomeStatus? {
            CoverageReconciliationQueue.temporaryHomeStatus(id: id, defaults: defaults)
        }
        let older = CoverageReconciliationQueue.enqueue(.temporaryHome, id: id, defaults: defaults)
        CoverageReconciliationQueue.recordTemporaryHomeOutcome(.failed, for: older, defaults: defaults)
        #expect(status() == .failed)
        CoverageReconciliationQueue.recordTemporaryHomeOutcome(
            .deferred(stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 0),
            for: older, defaults: defaults)
        #expect(status() == .waiting)

        // A later edit's entry: the older run's outcome no longer speaks for it.
        let newer = CoverageReconciliationQueue.stage(.temporaryHome, id: id, defaults: defaults)
        #expect(status() == .updating)
        CoverageReconciliationQueue.recordTemporaryHomeOutcome(.failed, for: older, defaults: defaults)
        #expect(status() == .updating)
        CoverageReconciliationQueue.recordTemporaryHomeOutcome(.failed, for: newer.entry, defaults: defaults)
        #expect(status() == .failed)

        // The newer save failed: its entry is withdrawn and the older one's
        // debt is back, whose own record was replaced.
        CoverageReconciliationQueue.withdraw(newer, defaults: defaults)
        #expect(status() == .updating)
        CoverageReconciliationQueue.recordTemporaryHomeOutcome(.failed, for: older, defaults: defaults)
        #expect(status() == .failed)
        CoverageReconciliationQueue.complete(older, defaults: defaults)
        #expect(status() == nil)
        #expect(defaults.object(forKey: CoverageReconciliationQueue.temporaryHomeStatusKey) == nil)
    }

    @Test("Try Again queues the temporary home afresh and drains it: a failed one reads as updating while its unit runs, and is gone once that unit settles")
    func retryTemporaryHomeSettlesAFailedEntry() async throws {
        let (defaults, suite) = try temporaryHomeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let log = TemporaryHomeDrainLog()
        CoverageReconciliationQueue.enqueue(.temporaryHome, id: id, defaults: defaults)
        await CoverageReconciliationQueue.drainIfNeeded(
            defaults: defaults, stages: temporaryHomeStages(log, temporary: [id: .failed]))
        #expect(CoverageReconciliationQueue.temporaryHomeStatus(id: id, defaults: defaults) == .failed)

        log.events = []
        var seen: CoverageReconciliationQueue.TemporaryHomeStatus?
        var stages = temporaryHomeStages(log, temporary: [
            id: .committed(stamped: 0, freed: 1, rebuiltTrips: 0, protectedTrips: 0),
        ])
        let apply = stages.applyTemporaryHome
        stages.applyTemporaryHome = { id, onSettled in
            seen = CoverageReconciliationQueue.temporaryHomeStatus(id: id, defaults: defaults)
            return await apply(id, onSettled)
        }
        await CoverageReconciliationQueue.retryTemporaryHome(id: id, defaults: defaults, stages: stages)
        #expect(seen == .updating)
        #expect(log.events == ["temporary", "titles", "publish temporary", "heal"])
        #expect(CoverageReconciliationQueue.temporaryHomeStatus(id: id, defaults: defaults) == nil)
        #expect(CoverageReconciliationQueue.pending(defaults: defaults).isEmpty)
    }
}
