//
//  CoverageReconciliationTests.swift
//  TravelLogTests
//
//  Home and routine coverage reconciliation report a checked outcome
//  (a failed read or save rolls the unit back, never a silent count), and a
//  device-local queue keeps an owed reconciliation until its unit settles so
//  activation and launch can finish it after a failure, a cancellation or a
//  kill.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite(.serialized)
struct CoverageReconciliationTests {

    private static let day: TimeInterval = 24 * 60 * 60
    private func date(day offset: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: -29_030_400 + offset * Self.day)
    }

    private let gym = (lat: 37.9192, lon: 23.7610)
    /// ~1.2 km from the gym: inside a 2 km ring.
    private let nearGym = (lat: 37.9299, lon: 23.7611)

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "CoverageReconciliationTests-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    @discardableResult
    private func makeStay(
        in ctx: ModelContext, startDay: Double, category: StayCategory,
        latitude: Double, longitude: Double = 0, distanceFromHomeKm: Double = 0
    ) -> Stay {
        let start = date(day: startDay)
        let stay = Stay(
            startTime: start, endTime: start.addingTimeInterval(3 * 3600),
            centroidLatitude: latitude, centroidLongitude: longitude,
            h3IndexRes6: "8a2a1072b59ffff", pingCount: 2,
            distanceFromHomeKm: distanceFromHomeKm, pingIDs: [])
        stay.category = category
        ctx.insert(stay)
        return stay
    }

    /// HomeChangeSemanticsTests' mid-trip scenario: Home B is registered
    /// after arriving, so reconciliation backdates it and resets three stays.
    private func makeMidTripHomeB(
        in ctx: ModelContext
    ) throws -> (homeB: Home, arrivalID: UUID, tripID: UUID) {
        let homeA = Home(label: "A", latitude: 0, longitude: 0, radiusKm: 25)
        homeA.startedAt = date(day: -100)
        ctx.insert(homeA)
        makeStay(in: ctx, startDay: 0, category: .home, latitude: 0)
        let waypoint = makeStay(in: ctx, startDay: 2, category: .destination,
                                latitude: 1, distanceFromHomeKm: 111)
        let arrival = makeStay(in: ctx, startDay: 4, category: .destination,
                               latitude: 2.0, distanceFromHomeKm: 222)
        let second = makeStay(in: ctx, startDay: 5, category: .destination,
                              latitude: 2.01, distanceFromHomeKm: 223)
        let third = makeStay(in: ctx, startDay: 6, category: .destination,
                             latitude: 2.0, distanceFromHomeKm: 222)
        let trip = Trip(startDate: date(day: 2))
        trip.isComplete = false
        ctx.insert(trip)
        for (index, stay) in [waypoint, arrival, second, third].enumerated() {
            stay.trip = trip
            stay.orderInTrip = index
        }
        homeA.endedAt = .now
        let homeB = Home(label: "B", latitude: 2, longitude: 0, radiusKm: 25)
        ctx.insert(homeB)
        try ctx.save()
        return (homeB, arrival.id, trip.id)
    }

    private func stay(_ id: UUID, _ container: ModelContainer) throws -> Stay? {
        try ModelContext(container).fetch(FetchDescriptor<Stay>(
            predicate: #Predicate { $0.id == id })).first
    }

    private func home(_ id: UUID, _ container: ModelContainer) throws -> Home? {
        try ModelContext(container).fetch(FetchDescriptor<Home>(
            predicate: #Predicate { $0.id == id })).first
    }

    // MARK: - Checked cores

    @Test("a failed Home reconciliation save rolls the unit back, and a retry completes it")
    func homeChangeSaveFailureRollsBackAndRetries() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let (homeB, arrivalID, tripID) = try makeMidTripHomeB(in: ctx)
        let homeBID = homeB.id
        let startedAt = homeB.startedAt

        let classifier = TripClassifier(modelContainer: container)
        await classifier.failNextReconciliationSaveForTesting()
        #expect(await classifier.applyHomeChangeCore(homeID: homeBID) == .failed)
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        #expect(try home(homeBID, container)?.startedAt == startedAt)
        let kept = try #require(try stay(arrivalID, container))
        #expect(kept.category == .destination)
        #expect(kept.trip?.id == tripID)

        #expect(await classifier.applyHomeChangeCore(homeID: homeBID)
                == .committed(resetCount: 3))
        #expect(try home(homeBID, container)?.startedAt == date(day: 4))
        let reset = try #require(try stay(arrivalID, container))
        #expect(reset.category == .unclassified)
        #expect(reset.trip == nil)
    }

    @Test("a failed Home reconciliation through the real entry point reports failure and does not settle")
    func homeChangeEntryPointReportsFailure() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let (homeB, arrivalID, tripID) = try makeMidTripHomeB(in: ctx)
        let classifier = TripClassifier(modelContainer: container)
        await classifier.failNextReconciliationSaveForTesting()
        let log = DrainLog()

        let outcome = await classifier.applyHomeChange(
            homeID: homeB.id, gate: PipelineGate(forTesting: ()),
            onSettled: { log.events.append("settled") })

        #expect(outcome == .failed)
        #expect(log.events.isEmpty, "a failed unit must not discharge its queue entry")
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        #expect(try stay(arrivalID, container)?.trip?.id == tripID)
    }

    @Test("a reconciliation cancelled while queued behind the pipeline reports cancellation")
    func queuedReconciliationCancellation() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let classifier = TripClassifier(modelContainer: container)
        await classifier.setRunningLatchForTesting(true)
        let task = Task {
            await classifier.applyHomeChange(
                homeID: UUID(), gate: PipelineGate(forTesting: ()))
        }
        task.cancel()
        #expect(await task.value == .cancelled)
        await classifier.setRunningLatchForTesting(false)
    }

    @Test("a failed routine reconciliation save rolls the unit back, and a retry completes it")
    func routineChangeSaveFailureRollsBackAndRetries() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let place = RoutinePlace(label: "Gym", latitude: gym.lat, longitude: gym.lon,
                                 radiusMeters: 2000, startedAt: date(day: -10))
        ctx.insert(place)
        let inRing = makeStay(in: ctx, startDay: 1, category: .destination,
                              latitude: nearGym.lat, longitude: nearGym.lon)
        try ctx.save()
        let stayID = inRing.id

        let classifier = TripClassifier(modelContainer: container)
        await classifier.failNextReconciliationSaveForTesting()
        #expect(await classifier.applyRoutinePlaceChangeCoreForTesting(placeID: place.id) == .failed)
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        #expect(try stay(stayID, container)?.category == .destination)

        #expect(await classifier.applyRoutinePlaceChangeCoreForTesting(placeID: place.id)
                == .committed(resetCount: 1))
        #expect(try stay(stayID, container)?.category == .unclassified)
    }

    @Test("an unreadable stay table fails both cores without mutating")
    func stayReadFailureFailsBothCores() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let (homeB, _, _) = try makeMidTripHomeB(in: ctx)
        let place = RoutinePlace(label: "Gym", latitude: gym.lat, longitude: gym.lon,
                                 radiusMeters: 2000, startedAt: date(day: -10))
        ctx.insert(place)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        classifier.failReconciliationStayReadForTesting = true
        defer { classifier.failReconciliationStayReadForTesting = false }
        #expect(await classifier.applyHomeChangeCore(homeID: homeB.id) == .failed)
        #expect(await classifier.applyRoutinePlaceChangeCoreForTesting(placeID: place.id) == .failed)
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
    }

    @Test("a row absent from the store settles as missing")
    func missingRowsSettle() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.applyHomeChangeCore(homeID: UUID()) == .placeMissing)
        #expect(await classifier.applyRoutinePlaceChangeCoreForTesting(placeID: UUID()) == .placeMissing)
    }

    // MARK: - Pending queue

    @Test("the Home and routine save workers queue the reconciliation with the committed edit, and not after a failed save")
    func workersQueueOnlyCommittedEdits() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let homeRow = Home(label: "Home", latitude: 37.9192, longitude: 23.7610, radiusKm: 3)
        ctx.insert(homeRow)
        let place = RoutinePlace(label: "Gym", latitude: gym.lat, longitude: gym.lon,
                                 radiusMeters: 500)
        ctx.insert(place)
        try ctx.save()
        func homePayload(radiusKm: Double) -> HomeSavePayload {
            HomeSavePayload(
                target: .edit(homeRow.id), label: "Home", latitude: 37.9192,
                longitude: 23.7610, radiusKm: radiusKm, locality: nil,
                administrativeArea: nil, country: nil, isoCountryCode: nil,
                endingExistingHomes: false, shownActiveHomeIDs: [], now: .now)
        }
        func placePayload(radiusMeters: Double) -> RoutinePlaceSavePayload {
            RoutinePlaceSavePayload(
                target: .edit(place.id), label: "Gym", latitude: gym.lat,
                longitude: gym.lon, radiusMeters: radiusMeters, now: .now)
        }

        let failedHome = HomeSaveWorker.apply(
            homePayload(radiusKm: 5), context: ctx,
            save: { _ in throw CocoaError(.fileWriteUnknown) }, pendingDefaults: defaults)
        #expect(failedHome.failed)
        let failedPlace = RoutinePlaceSaveWorker.apply(
            placePayload(radiusMeters: 800), context: ctx,
            save: { _ in throw CocoaError(.fileWriteUnknown) }, pendingDefaults: defaults)
        #expect(failedPlace.failed)
        #expect(CoverageReconciliationQueue.pending(defaults: defaults).isEmpty)

        let savedHome = HomeSaveWorker.apply(
            homePayload(radiusKm: 5), context: ctx, pendingDefaults: defaults)
        let homeEntry = try #require(savedHome.pendingReconciliation)
        #expect(homeEntry.kind == .home && homeEntry.id == homeRow.id)
        let savedPlace = RoutinePlaceSaveWorker.apply(
            placePayload(radiusMeters: 800), context: ctx, pendingDefaults: defaults)
        let placeEntry = try #require(savedPlace.pendingReconciliation)
        #expect(placeEntry.kind == .routinePlace && placeEntry.id == place.id)
        #expect(CoverageReconciliationQueue.pending(defaults: defaults) == [homeEntry, placeEntry])
    }

    @Test("a failed later edit of the same Home or routine place keeps the earlier committed edit's owed reconciliation")
    func failedLaterEditKeepsEarlierDebt() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let homeRow = Home(label: "Home", latitude: 37.9192, longitude: 23.7610, radiusKm: 3)
        ctx.insert(homeRow)
        let place = RoutinePlace(label: "Gym", latitude: gym.lat, longitude: gym.lon,
                                 radiusMeters: 500)
        ctx.insert(place)
        try ctx.save()
        func homePayload(radiusKm: Double) -> HomeSavePayload {
            HomeSavePayload(
                target: .edit(homeRow.id), label: "Home", latitude: 37.9192,
                longitude: 23.7610, radiusKm: radiusKm, locality: nil,
                administrativeArea: nil, country: nil, isoCountryCode: nil,
                endingExistingHomes: false, shownActiveHomeIDs: [], now: .now)
        }
        func placePayload(radiusMeters: Double) -> RoutinePlaceSavePayload {
            RoutinePlaceSavePayload(
                target: .edit(place.id), label: "Gym", latitude: gym.lat,
                longitude: gym.lon, radiusMeters: radiusMeters, now: .now)
        }

        // Edit A commits; its reconciliation has not settled (it failed,
        // was cancelled or the app was killed), so its entry stays owed.
        let homeA = try #require(HomeSaveWorker.apply(
            homePayload(radiusKm: 5), context: ctx, pendingDefaults: defaults)
            .pendingReconciliation)
        let placeA = try #require(RoutinePlaceSaveWorker.apply(
            placePayload(radiusMeters: 800), context: ctx, pendingDefaults: defaults)
            .pendingReconciliation)

        // Edit B of the same rows fails to save.
        #expect(HomeSaveWorker.apply(
            homePayload(radiusKm: 7), context: ctx,
            save: { _ in throw CocoaError(.fileWriteUnknown) },
            pendingDefaults: defaults).failed)
        #expect(RoutinePlaceSaveWorker.apply(
            placePayload(radiusMeters: 1200), context: ctx,
            save: { _ in throw CocoaError(.fileWriteUnknown) },
            pendingDefaults: defaults).failed)

        // A's committed coverage still owes its reconciliation, under A's
        // own token, so A's in-flight run or a drain can still settle it.
        #expect(homeRow.radiusKm == 5 && place.radiusMeters == 800)
        #expect(CoverageReconciliationQueue.pending(defaults: defaults) == [homeA, placeA])
        CoverageReconciliationQueue.complete(homeA, defaults: defaults)
        CoverageReconciliationQueue.complete(placeA, defaults: defaults)
        #expect(defaults.object(forKey: CoverageReconciliationQueue.pendingKey) == nil)
    }

    @Test("withdrawing a staged entry restores what it superseded, only while it owns the slot")
    func withdrawalIsConditional() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()

        // Nothing superseded: withdrawal leaves no entry.
        let lone = CoverageReconciliationQueue.stage(.home, id: id, defaults: defaults)
        CoverageReconciliationQueue.withdraw(lone, defaults: defaults)
        #expect(defaults.object(forKey: CoverageReconciliationQueue.pendingKey) == nil)

        // A superseded entry comes back.
        let earlier = CoverageReconciliationQueue.enqueue(.home, id: id, defaults: defaults)
        let failed = CoverageReconciliationQueue.stage(.home, id: id, defaults: defaults)
        CoverageReconciliationQueue.withdraw(failed, defaults: defaults)
        #expect(CoverageReconciliationQueue.pending(defaults: defaults) == [earlier])

        // A staged entry that no longer owns the slot changes nothing.
        let stale = CoverageReconciliationQueue.stage(.home, id: id, defaults: defaults)
        let newest = CoverageReconciliationQueue.enqueue(.home, id: id, defaults: defaults)
        CoverageReconciliationQueue.withdraw(stale, defaults: defaults)
        #expect(CoverageReconciliationQueue.pending(defaults: defaults) == [newest])
    }

    @Test("completion drops only the entry's own token")
    func completionIsConditional() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let older = CoverageReconciliationQueue.enqueue(.home, id: id, defaults: defaults)
        let newer = CoverageReconciliationQueue.enqueue(.home, id: id, defaults: defaults)
        CoverageReconciliationQueue.complete(older, defaults: defaults)
        #expect(CoverageReconciliationQueue.pending(defaults: defaults) == [newer])
        CoverageReconciliationQueue.complete(newer, defaults: defaults)
        #expect(CoverageReconciliationQueue.pending(defaults: defaults).isEmpty)
        #expect(defaults.object(forKey: CoverageReconciliationQueue.pendingKey) == nil)
    }

    private final class DrainLog {
        var events: [String] = []
        var newer: CoverageReconciliationQueue.Entry?
    }

    private func stages(
        _ log: DrainLog,
        outcomes: [UUID: TripClassifier.CoverageReconciliationOutcome],
        persistentStore: Bool = true,
        beforeReturn: @escaping @MainActor @Sendable (UUID) -> Void = { _ in }
    ) -> CoverageReconciliationQueue.Stages {
        CoverageReconciliationQueue.Stages(
            applyHome: { id, onSettled in
                log.events.append("home")
                beforeReturn(id)
                let outcome = outcomes[id] ?? .failed
                if outcome.isSettled { onSettled() }
                return outcome
            },
            applyRoutinePlace: { id, onSettled in
                log.events.append("routine")
                beforeReturn(id)
                let outcome = outcomes[id] ?? .failed
                if outcome.isSettled { onSettled() }
                return outcome
            },
            generateLocalizedTitles: { log.events.append("titles") },
            publish: { homes, routinePlaces in
                log.events.append("publish \(homes) \(routinePlaces)")
            },
            heal: { log.events.append("heal") },
            isPersistentStore: { persistentStore })
    }

    @Test("the drain keeps failed and cancelled work, then runs titles, publication and healing once, in Settings' order")
    func drainKeepsUnsettledWorkAndOrdersFollowUps() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let committed = UUID(), failed = UUID(), missing = UUID(), cancelled = UUID()
        CoverageReconciliationQueue.enqueue(.home, id: committed, defaults: defaults)
        let failedEntry = CoverageReconciliationQueue.enqueue(.home, id: failed, defaults: defaults)
        CoverageReconciliationQueue.enqueue(.home, id: missing, defaults: defaults)
        let cancelledEntry = CoverageReconciliationQueue.enqueue(
            .routinePlace, id: cancelled, defaults: defaults)
        let log = DrainLog()

        let drained = await CoverageReconciliationQueue.drainIfNeeded(
            defaults: defaults,
            stages: stages(log, outcomes: [
                committed: .committed(resetCount: 2), failed: .failed,
                missing: .placeMissing, cancelled: .cancelled,
            ]))

        #expect(!drained)
        #expect(log.events == ["home", "home", "home", "routine",
                               "titles", "publish true false", "heal"])
        #expect(Set(CoverageReconciliationQueue.pending(defaults: defaults).map(\.id))
                == [failedEntry.id, cancelledEntry.id])
        #expect(CoverageReconciliationQueue.pending(defaults: defaults)
            .first { $0.id == failed } == failedEntry)
    }

    @Test("a newer edit queued while its older reconciliation drains stays queued")
    func newerEditSurvivesOlderDrain() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        CoverageReconciliationQueue.enqueue(.routinePlace, id: id, defaults: defaults)
        let log = DrainLog()

        let drained = await CoverageReconciliationQueue.drainIfNeeded(
            defaults: defaults,
            stages: stages(log, outcomes: [id: .committed(resetCount: 0)]) { _ in
                // The user edits the same place again mid-reconciliation.
                log.newer = CoverageReconciliationQueue.enqueue(
                    .routinePlace, id: id, defaults: defaults)
            })

        #expect(drained)
        #expect(log.events == ["routine", "titles", "publish false true"])
        let pending = CoverageReconciliationQueue.pending(defaults: defaults)
        #expect(pending == [try #require(log.newer)])
    }

    @Test("a drain on the in-memory fallback store keeps every marker for the persistent store's next drain")
    func fallbackStoreDrainKeepsMarkers() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let homeID = UUID(), placeID = UUID()
        let homeEntry = CoverageReconciliationQueue.enqueue(.home, id: homeID, defaults: defaults)
        let placeEntry = CoverageReconciliationQueue.enqueue(
            .routinePlace, id: placeID, defaults: defaults)
        let log = DrainLog()

        // The empty fallback store would report every queued row missing.
        let onFallback = await CoverageReconciliationQueue.drainIfNeeded(
            defaults: defaults,
            stages: stages(log, outcomes: [homeID: .placeMissing, placeID: .placeMissing],
                           persistentStore: false))
        #expect(!onFallback)
        #expect(log.events.isEmpty)
        #expect(CoverageReconciliationQueue.pending(defaults: defaults) == [homeEntry, placeEntry])

        // A later launch on the persistent store reconciles and clears them.
        let onPersistent = await CoverageReconciliationQueue.drainIfNeeded(
            defaults: defaults,
            stages: stages(log, outcomes: [
                homeID: .committed(resetCount: 1), placeID: .committed(resetCount: 1),
            ]))
        #expect(onPersistent)
        #expect(log.events == ["home", "routine", "titles", "publish true true", "heal"])
        #expect(defaults.object(forKey: CoverageReconciliationQueue.pendingKey) == nil)
    }

    @Test("an empty queue runs nothing")
    func emptyDrainIsNoOp() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = DrainLog()
        #expect(await CoverageReconciliationQueue.drainIfNeeded(
            defaults: defaults, stages: stages(log, outcomes: [:])))
        #expect(log.events.isEmpty)
    }

    @Test("Delete Everything clears owed reconciliations and the Home alias log")
    func wipeClearsDeviceLocalCorrectionState() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        CoverageReconciliationQueue.enqueue(.home, id: UUID(), defaults: defaults)
        PlacesDeduplicator.storeHomeAliases([UUID(): UUID()], defaults: defaults)
        let container = try TestSupport.makeInMemoryContainer()

        #expect(DataWipe.execute(container: container, defaults: defaults))
        #expect(defaults.object(forKey: CoverageReconciliationQueue.pendingKey) == nil)
        #expect(defaults.object(forKey: PlacesDeduplicator.homeAliasesKey) == nil)
    }

    // MARK: - Completed-trip summaries need their home-place read

    /// A completed trip whose remnant keeps a stop named like the era Home
    /// ("Athens"): only a summary built with its home-place filter reads
    /// "Aegina". The middle stay is the one the edited ring detaches.
    private func makeCompletedTripWithHomeNamedStop(
        in ctx: ModelContext, detachedLatitude: Double, detachedLongitude: Double
    ) throws -> (detachedID: UUID, tripID: UUID) {
        let homeA = Home(label: "A", latitude: 0, longitude: 0, radiusKm: 25,
                         startedAt: date(day: -100))
        homeA.locality = "Athens"
        ctx.insert(homeA)
        let aegina = makeStay(in: ctx, startDay: 2, category: .destination,
                              latitude: 1, distanceFromHomeKm: 111)
        aegina.locality = "Aegina"
        let detached = makeStay(in: ctx, startDay: 4, category: .destination,
                                latitude: detachedLatitude, longitude: detachedLongitude,
                                distanceFromHomeKm: 222)
        detached.locality = "Lixoúri"
        let port = makeStay(in: ctx, startDay: 5, category: .destination,
                            latitude: 1.01, distanceFromHomeKm: 112)
        port.locality = "Athens"
        let trip = Trip(startDate: aegina.startTime)
        trip.isComplete = true
        trip.endDate = date(day: 6)
        trip.destinationSummary = "Aegina, Lixoúri"
        trip.aiGeneratedSummary = "Island hopping"
        ctx.insert(trip)
        for (index, stay) in [aegina, detached, port].enumerated() {
            stay.trip = trip
            stay.orderInTrip = index
        }
        try ctx.save()
        return (detached.id, trip.id)
    }

    /// Stages that run the classifier's real units. `entryPoints` goes through
    /// the gated Settings entry points; otherwise the cores run directly, so a
    /// committed reset does not start the Stage 2 pipeline pass.
    private func classifierStages(
        _ log: DrainLog, _ classifier: TripClassifier, entryPoints: Bool
    ) -> CoverageReconciliationQueue.Stages {
        CoverageReconciliationQueue.Stages(
            applyHome: { id, onSettled in
                log.events.append("home")
                if entryPoints {
                    return await classifier.applyHomeChange(
                        homeID: id, gate: PipelineGate(forTesting: ()), onSettled: onSettled)
                }
                let outcome = await classifier.applyHomeChangeCore(homeID: id)
                if outcome.isSettled { onSettled() }
                return outcome
            },
            applyRoutinePlace: { id, onSettled in
                log.events.append("routine")
                if entryPoints {
                    return await classifier.applyRoutinePlaceChange(
                        placeID: id, gate: PipelineGate(forTesting: ()), onSettled: onSettled)
                }
                let outcome = await classifier.applyRoutinePlaceChangeCoreForTesting(placeID: id)
                if outcome.isSettled { onSettled() }
                return outcome
            },
            generateLocalizedTitles: { log.events.append("titles") },
            publish: { homes, routinePlaces in
                log.events.append("publish \(homes) \(routinePlaces)")
            },
            heal: { log.events.append("heal") },
            isPersistentStore: { true })
    }

    @Test("an unreadable home-place index fails a completed trip's Home or routine reconciliation and keeps its debt until a retry commits the filtered summary",
          IsolatedTitleDefaults(), arguments: [false, true])
    func completedTripSummaryReadFailureKeepsDebt(routine: Bool) async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let detachedAt = routine ? nearGym : (lat: 2.0, lon: 0.0)
        let (detachedID, tripID) = try makeCompletedTripWithHomeNamedStop(
            in: ctx, detachedLatitude: detachedAt.lat, detachedLongitude: detachedAt.lon)
        let editedID: UUID
        var homeBID: UUID?
        if routine {
            let place = RoutinePlace(label: "Gym", latitude: gym.lat, longitude: gym.lon,
                                     radiusMeters: 2000, startedAt: date(day: -10))
            ctx.insert(place)
            editedID = place.id
        } else {
            let homeB = Home(label: "B", latitude: 2, longitude: 0, radiusKm: 25,
                             startedAt: date(day: 3))
            ctx.insert(homeB)
            editedID = homeB.id
            homeBID = homeB.id
        }
        try ctx.save()
        let entry = CoverageReconciliationQueue.enqueue(
            routine ? .routinePlace : .home, id: editedID, defaults: defaults)
        let classifier = TripClassifier(modelContainer: container)
        let log = DrainLog()
        let unit = routine ? "routine" : "home"

        // The unit's own reads succeed; only the summary's home-place fill fails.
        let drained = await TripTitleStore.HomePlaceIndex.$failFetchForTesting.withValue(true) {
            await CoverageReconciliationQueue.drainIfNeeded(
                defaults: defaults,
                stages: classifierStages(log, classifier, entryPoints: true))
        }

        #expect(!drained)
        #expect(log.events == [unit], "a failed unit runs no titles, publication or healing")
        #expect(CoverageReconciliationQueue.pending(defaults: defaults) == [entry])
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        var trip = try #require(try ModelContext(container).fetch(FetchDescriptor<Trip>(
            predicate: #Predicate { $0.id == tripID })).first)
        #expect(trip.destinationSummary == "Aegina, Lixoúri")
        #expect(trip.aiGeneratedSummary == "Island hopping")
        let kept = try #require(try stay(detachedID, container))
        #expect(kept.category == .destination)
        #expect(kept.trip?.id == tripID)
        if let homeBID {
            #expect(try home(homeBID, container)?.startedAt == date(day: 3))
        }

        let retried = await CoverageReconciliationQueue.drainIfNeeded(
            defaults: defaults,
            stages: classifierStages(log, classifier, entryPoints: false))

        #expect(retried)
        #expect(CoverageReconciliationQueue.pending(defaults: defaults).isEmpty)
        #expect(log.events == (routine
            ? ["routine", "routine", "titles", "publish false true"]
            : ["home", "home", "titles", "publish true false", "heal"]))
        trip = try #require(try ModelContext(container).fetch(FetchDescriptor<Trip>(
            predicate: #Predicate { $0.id == tripID })).first)
        #expect(trip.destinationSummary == "Aegina")
        #expect(trip.aiGeneratedSummary == "Island hopping", "the shrink keeps the stored narrative")
        let reset = try #require(try stay(detachedID, container))
        #expect(reset.category == .unclassified)
        #expect(reset.trip == nil)
    }
}
