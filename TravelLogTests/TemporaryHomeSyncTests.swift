//
//  TemporaryHomeSyncTests.swift
//  TravelLogTests
//
//  Temporary homes across devices. A home stay records
//  the temporary home that stamped it and the coverage revision of that copy,
//  a pair every writer sets and clears together; the save worker moves the
//  revision once per coverage change. A unit for a live declaration frees or
//  hands on only stamps no newer than its own copy and defers the rest,
//  keeping its debt; removal frees them all. Deferred stamps that never win
//  are released after a day by reissuing the declaration above them. The
//  drain discovers work for a live declaration from what its last committed
//  unit processed and left, which that unit acknowledges in a device-local
//  file. Throwaway stores, primed square shapes, the model lane pinned off.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
private final class SyncDrainLog {
    var events: [String] = []
    /// Full discovery reads.
    var reads = 0
}

/// Mutable inputs a test hands the drain: the favourites, and the store
/// generation a `DiscoveryThrottle` reads (what a remote push or a gated
/// write would advance).
@MainActor
private final class SyncInputs {
    var favourites: Set<UUID> = []
    var generation = 0
}

extension ReconciliationDrainTests {
@MainActor
@Suite("Temporary home sync", .serialized, IsolatedTitleDefaults())
struct TemporaryHomeSyncTests {

    private typealias Place = (lat: Double, lon: Double)
    private typealias Outcome = TripClassifier.TemporaryHomeReconciliationOutcome
    private typealias Acknowledgements = CoverageReconciliationQueue.Acknowledgements
    private static let athens: Place = (38.0, 23.8)
    /// Nonisolated: a default argument reads it.
    nonisolated private static let brussels: Place = (50.85, 4.35)
    /// About 50 km north of Brussels, outside its 10 km square.
    private static let outing: Place = (51.30, 4.35)

    private nonisolated static let dayZero: Double = -161

    private func date(_ day: Double) -> Date { TemporaryHomeFixture.date(day + Self.dayZero) }

    @discardableResult
    private func stay(
        _ ctx: ModelContext, _ place: Place, day: Double, days: Double = 0.8,
        _ category: StayCategory = .unclassified
    ) -> Stay {
        let start = date(day)
        return TemporaryHomeFixture.stay(
            ctx, place, from: start, to: start.addingTimeInterval(days * 86_400), category,
            hex: "P", pingCount: 2, source: .liveSLC, zone: "GMT")
    }

    /// A home stay another device stamped: its provenance pair as it synced in.
    @discardableResult
    private func stamp(
        _ ctx: ModelContext, _ place: Place, day: Double, by id: UUID, revision: Int?
    ) -> Stay {
        let row = stay(ctx, place, day: day, .home)
        row.setTemporaryHomeProvenance(id, revision: revision)
        return row
    }

    @discardableResult
    private func trip(_ ctx: ModelContext, _ stays: [Stay], name: String? = nil) -> Trip {
        let trip = TemporaryHomeFixture.trip(ctx, stays, complete: true)
        if let name {
            trip.customName = name
            trip.userEdited = true
        }
        return trip
    }

    /// The real home in Athens since long before the fixture, with a home stay on day 0.
    private func seedAthens(_ ctx: ModelContext) {
        let home = TemporaryHomeFixture.realHome(ctx, "Athens", at: Self.athens)
        home.startedAt = date(-1000)
        stay(ctx, Self.athens, day: 0, .home)
    }

    @discardableResult
    private func temporaryHome(
        _ ctx: ModelContext, at place: Place = brussels, from: Double = 10,
        until: Double? = nil, revision: Int = 1, modifiedDay: Double = 5
    ) -> TemporaryHome {
        let row = TemporaryHomeFixture.temporaryHome(
            ctx, "Semester", at: place, from: from + Self.dayZero,
            until: until.map { $0 + Self.dayZero }, zone: "GMT")
        row.coverageRevision = revision
        row.modifiedAt = date(modifiedDay)
        return row
    }

    private func makeClassifier(_ container: ModelContainer) async -> TripClassifier {
        await TemporaryHomeFixture.classifier(container, squares: [(1, Self.athens), (2, Self.brussels)])
    }

    private func reconcile(
        _ classifier: TripClassifier, _ id: UUID,
        deferredSince: Date? = nil, now: Date = .now
    ) async -> Outcome {
        await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: id, pinnedTripIDs: [], deferredSince: deferredSince, now: now)
    }

    /// One ordinary pipeline pass.
    private func ordinaryPass(_ classifier: TripClassifier) async {
        await TemporaryHomeFixture.ordinaryPass(classifier)
    }

    /// Writes every row with the id as a synced copy lands: no save worker,
    /// so nothing is queued.
    private func editRows(
        _ id: UUID, _ container: ModelContainer, _ change: (TemporaryHome) -> Void
    ) throws {
        let ctx = ModelContext(container)
        for row in try ctx.fetch(FetchDescriptor<TemporaryHome>()) where row.id == id {
            change(row)
            row.modifiedAt = date(120)
        }
        try ctx.save()
    }

    private func declarationRows(_ id: UUID, _ container: ModelContainer) throws -> [TemporaryHome] {
        try ModelContext(container).fetch(FetchDescriptor<TemporaryHome>())
            .filter { $0.id == id }
    }

    private func stored(_ id: UUID, _ container: ModelContainer) throws -> Stay {
        let found = try ModelContext(container).fetch(FetchDescriptor<Stay>(
            predicate: #Predicate { $0.id == id }))
        try #require(found.count == 1)
        return found[0]
    }

    private func trips(_ container: ModelContainer) throws -> [Trip] {
        try ModelContext(container).fetch(FetchDescriptor<Trip>())
    }

    /// A UserDefaults suite and an acknowledgement directory of the test's own.
    private func scratch() throws -> (defaults: UserDefaults, suite: String, directory: URL) {
        let suite = "TemporaryHomeSyncTests-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TemporaryHomeSyncTests-\(UUID().uuidString)", isDirectory: true)
        return (try #require(UserDefaults(suiteName: suite)), suite, directory)
    }

    private func cleanUp(_ scratch: (defaults: UserDefaults, suite: String, directory: URL)) {
        scratch.defaults.removePersistentDomain(forName: scratch.suite)
        try? FileManager.default.removeItem(at: scratch.directory)
    }

    private func owed(_ defaults: UserDefaults) -> [UUID] {
        CoverageReconciliationQueue.pending(defaults: defaults)
            .filter { $0.kind == .temporaryHome }.map(\.id)
    }

    // MARK: - Production orchestration on a test store

    /// `CoverageReconciliationQueue.drainIfNeeded` with `.live`'s stages
    /// pointed at this classifier and store: the real temporary-home entry
    /// point, real removal and live discovery, acknowledgements in `directory`.
    /// `favourites` stand for the favourites the unit and discovery read; a
    /// `throttle` (none by default) stands for the live one.
    @discardableResult
    private static func drain(
        _ classifier: TripClassifier, _ container: ModelContainer,
        defaults: UserDefaults, directory: URL, log: SyncDrainLog,
        heal: @escaping @MainActor @Sendable () async -> Void = {},
        favourites: @escaping @MainActor @Sendable () -> Set<UUID> = { [] },
        throttle: CoverageReconciliationQueue.DiscoveryThrottle? = nil
    ) async -> Bool {
        let stages = CoverageReconciliationQueue.Stages(
            applyHome: { _, _ in
                log.events.append("home")
                return .failed
            },
            applyRoutinePlace: { _, _ in
                log.events.append("routine")
                return .failed
            },
            applyTemporaryHome: { id, onSettled in
                log.events.append("temporary")
                return await StayClassificationInference.TestHook.$availability.withValue(false) {
                    await classifier.applyTemporaryHomeChange(
                        temporaryHomeID: id, pinnedTripIDs: { favourites() },
                        gate: PipelineGate(forTesting: ()), unpinRetired: { _ in },
                        acknowledgementDirectory: directory, onSettled: onSettled)
                }
            },
            generateLocalizedTitles: {},
            publish: { _, _ in },
            publishTemporaryHomes: {},
            heal: { await heal() },
            isPersistentStore: { true },
            removalEvidence: {
                try? CoverageReconciliationQueue.removalEvidence(in: ModelContext(container))
            },
            discoveryDigests: {
                log.reads += 1
                return await classifier.temporaryHomeDiscoveryDigests(pinnedTripIDs: favourites())
            },
            acknowledgementDirectory: directory,
            discoveryThrottle: throttle)
        return await CoverageReconciliationQueue.drainIfNeeded(defaults: defaults, stages: stages)
    }

    /// `HomeAreaHealing.healIfNeeded` with `.live`'s stages pointed at this
    /// classifier (its rescue, title and widget stages are no-ops here).
    @discardableResult
    private static func heal(_ classifier: TripClassifier, defaults: UserDefaults) async -> Bool {
        let gate = PipelineGate(forTesting: ())
        let stages = HomeAreaHealing.Stages(
            rescue: {},
            fingerprint: { await classifier.homeAreaFingerprint() },
            heal: { staleCoverage in
                await gate.runReturning(touching: [.stay, .trip]) {
                    await classifier.healHomeAreaCorrections(
                        pinnedTripIDs: [], staleCoverage: staleCoverage)
                }
            },
            drainParked: { await classifier.drainParkedDissolvedTrips() },
            classify: {
                await StayClassificationInference.TestHook.$availability.withValue(false) {
                    await classifier.classifyAndAssembleTripsQueuedWithGates(
                        maxStaysPerCall: nil, gate: gate)
                }
            },
            generateTitles: {},
            coverage: { try await classifier.homeAreaCoverage() },
            bumpChanges: {},
            reloadWidgets: {})
        return await HomeAreaHealing.healIfNeeded(defaults: defaults, stages: stages)
    }

    // MARK: - Provenance pairs

    @Test("the ordinary pass stamps a temporary home's stay with the revision of the copy readers resolve to, not a losing twin's, and a real Home's stay with neither half")
    func ordinaryStampCarriesTheCollapsedRevision() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let semester = temporaryHome(ctx, revision: 3, modifiedDay: 5)
        let twin = temporaryHome(ctx, revision: 7, modifiedDay: 4)
        twin.id = semester.id
        let during = stay(ctx, Self.brussels, day: 20)
        let atHome = stay(ctx, Self.athens, day: 21)
        try ctx.save()

        await ordinaryPass(await makeClassifier(container))
        let stamped = try stored(during.id, container)
        #expect(stamped.category == .home)
        #expect(stamped.temporaryHomeID == semester.id)
        #expect(stamped.temporaryHomeRevision == 3)
        let real = try stored(atHome.id, container)
        #expect(real.category == .home)
        #expect(real.temporaryHomeID == nil)
        #expect(real.temporaryHomeRevision == nil)
    }

    @Test("This Wasn't a Trip stamps each member with its temporary home's revision; Undo clears both halves")
    func correctionStampCarriesTheRevisionAndUndoClearsIt() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let semesterID = temporaryHome(ctx, revision: 4).id
        let day = stay(ctx, Self.outing, day: 13, .destination)
        let outing = trip(ctx, [day])
        try ctx.save()
        let classifier = await makeClassifier(container)

        #expect(await classifier.demoteTripToHomeArea(
            tripID: outing.id, tripIdentifier: outing.persistentModelID)
            == .demoted(tripName: outing.displayName))
        let demoted = try stored(day.id, container)
        #expect(demoted.category == .home)
        #expect(demoted.temporaryHomeID == semesterID)
        #expect(demoted.temporaryHomeRevision == 4)

        #expect(await classifier.undoLastDemotion() == .undone)
        let undone = try stored(day.id, container)
        #expect(undone.category == .destination)
        #expect(undone.temporaryHomeID == nil)
        #expect(undone.temporaryHomeRevision == nil)
    }

    @Test("a stay handed to the temporary home that still claims it takes that one's revision")
    func handoffTakesTheHeirsRevision() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let first = temporaryHome(ctx, from: 10, revision: 2).id
        let heir = temporaryHome(ctx, from: 15, revision: 5).id
        let shared = stay(ctx, Self.brussels, day: 30)
        try ctx.save()
        await ordinaryPass(await makeClassifier(container))
        let before = try stored(shared.id, container)
        #expect(before.temporaryHomeID == first)
        #expect(before.temporaryHomeRevision == 2)

        try editRows(first, container) { $0.removedAt = self.date(120) }
        #expect(await reconcile(await makeClassifier(container), first)
                == .committed(stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 0))
        let handed = try stored(shared.id, container)
        #expect(handed.category == .home)
        #expect(handed.temporaryHomeID == heir)
        #expect(handed.temporaryHomeRevision == 5)
    }

    @Test("a restored trip gives a recorded home stay its archived pair and clears both halves on any other stay, on a new row and on a row that came back holding a member",
          arguments: [false, true])
    func restoreBringsBackTheArchivedPair(rowCameBack: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let declaration = UUID()
        let present = stay(ctx, Self.outing, day: 13, .destination)
        let base = stay(ctx, Self.brussels, day: 14)
        let away = stay(ctx, Self.outing, day: 15)
        // A revision with no id, as no writer leaves one: the restore clears it.
        away.temporaryHomeRevision = 5
        let tripID = UUID()
        if rowCameBack {
            let returned = trip(ctx, [present])
            returned.id = tripID
        }
        try ctx.save()
        let record = DissolvedTripRecord(
            id: tripID, dissolvedAt: date(20), displayName: "Weekend",
            startDate: present.startTime, endDate: away.endTime, isComplete: true,
            destinationSummary: "Weekend", countryCodes: "BE", classifiedByAI: false,
            aiGeneratedTitle: nil, aiGeneratedSummary: nil, summarySourceRaw: nil,
            sourceRaw: DataSource.liveSLC.rawValue, customName: nil,
            userEdited: false, keptByTemporaryHome: nil,
            stays: [
                .init(id: present.id, categoryRaw: "destination", orderInTrip: 0),
                .init(id: base.id, categoryRaw: "home", orderInTrip: 1,
                      temporaryHomeID: declaration, temporaryHomeRevision: 3),
                .init(id: away.id, categoryRaw: "destination", orderInTrip: 2,
                      temporaryHomeID: declaration, temporaryHomeRevision: 3),
            ])

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.restoreDissolvedTrip(record, markStaysSacred: false) == .restored)
        let home = try stored(base.id, container)
        #expect(home.category == .home)
        #expect(home.temporaryHomeID == declaration)
        #expect(home.temporaryHomeRevision == 3)
        let other = try stored(away.id, container)
        #expect(other.category == .destination)
        #expect(other.temporaryHomeID == nil)
        #expect(other.temporaryHomeRevision == nil)
    }

    // MARK: - The save worker's revision

    @Test("the save worker moves the revision once per coverage change, past every row of the id, on every row it writes; a label or place-name change and an End that changes nothing leave it")
    func workerMovesTheRevisionOncePerCoverageChange() throws {
        let suite = "TemporaryHomeSyncTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_786_089_600)
        func payload(
            _ target: TemporaryHomeSavePayload.Target, label: String = "Erasmus",
            locality: String? = "Brussels", from: Date, until: Date? = nil
        ) -> TemporaryHomeSavePayload {
            TemporaryHomeSavePayload(
                target: target, label: label,
                latitude: Self.brussels.lat, longitude: Self.brussels.lon,
                locality: locality, administrativeArea: nil, country: "Belgium",
                isoCountryCode: "BE", startedAt: from, endedAt: until,
                timeZoneIdentifier: "Europe/Brussels", now: now)
        }
        func revisions() throws -> [Int] {
            try ModelContext(container).fetch(FetchDescriptor<TemporaryHome>())
                .map(\.coverageRevision).sorted()
        }
        let start = now.addingTimeInterval(-100 * 86_400)

        #expect(!TemporaryHomeSaveWorker.apply(
            payload(.add, from: start), context: ctx, pendingDefaults: defaults).failed)
        #expect(try revisions() == [1])
        let id = try #require(try ModelContext(container).fetch(FetchDescriptor<TemporaryHome>()).first).id

        // A twin from a backup restored on another device, at a higher revision.
        let seed = ModelContext(container)
        let twin = TemporaryHome(label: "Erasmus", latitude: Self.brussels.lat,
                                 longitude: Self.brussels.lon, startedAt: start)
        twin.id = id
        twin.coverageRevision = 3
        twin.modifiedAt = start
        seed.insert(twin)
        try seed.save()

        // New dates: one revision above both rows, on both.
        #expect(!TemporaryHomeSaveWorker.apply(
            payload(.edit(id), from: start.addingTimeInterval(86_400)),
            context: ctx, pendingDefaults: defaults).failed)
        #expect(try revisions() == [4, 4])
        // A new label or place name moves no stay.
        #expect(!TemporaryHomeSaveWorker.apply(
            payload(.edit(id), label: "Brussels year", locality: "Bruxelles",
                    from: start.addingTimeInterval(86_400)),
            context: ctx, pendingDefaults: defaults).failed)
        #expect(try revisions() == [4, 4])
        // End, then End on the same day again.
        #expect(!TemporaryHomeSaveWorker.apply(
            .ending(id, on: now.addingTimeInterval(-10 * 86_400), now: now),
            context: ctx, pendingDefaults: defaults).failed)
        #expect(try revisions() == [5, 5])
        #expect(!TemporaryHomeSaveWorker.apply(
            .ending(id, on: now.addingTimeInterval(-10 * 86_400), now: now),
            context: ctx, pendingDefaults: defaults).failed)
        #expect(try revisions() == [5, 5])
        // Removal is a coverage change too.
        #expect(!TemporaryHomeSaveWorker.apply(
            .removing(id, now: now), context: ctx, pendingDefaults: defaults).failed)
        #expect(try revisions() == [6, 6])
        #expect(try ModelContext(container).fetch(FetchDescriptor<TemporaryHome>())
            .allSatisfy { $0.removedAt != nil })
    }

    // MARK: - Release by revision

    @Test("a unit acting on an older copy frees stamps at or below its revision and legacy ones, leaves a newer copy's stamp home and says it deferred")
    func staleCopyDefersANewerStamp() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let semester = temporaryHome(ctx, until: 30, revision: 1).id
        let newer = stamp(ctx, Self.brussels, day: 40, by: semester, revision: 2)
        let same = stamp(ctx, Self.brussels, day: 45, by: semester, revision: 1)
        let legacy = stamp(ctx, Self.brussels, day: 50, by: semester, revision: nil)
        try ctx.save()

        #expect(await reconcile(await makeClassifier(container), semester)
                == .deferred(stamped: 0, freed: 2, rebuiltTrips: 0, protectedTrips: 0))
        let waiting = try stored(newer.id, container)
        #expect(waiting.category == .home)
        #expect(waiting.temporaryHomeID == semester)
        #expect(waiting.temporaryHomeRevision == 2)
        for id in [same.id, legacy.id] {
            let freed = try stored(id, container)
            #expect(freed.category == .unclassified)
            #expect(freed.temporaryHomeID == nil)
            #expect(freed.temporaryHomeRevision == nil)
        }
    }

    @Test("a newer copy's stamp is not handed to another temporary home either")
    func staleCopyDefersAHandoff() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let semester = temporaryHome(ctx, from: 10, until: 15, revision: 1).id
        temporaryHome(ctx, from: 16, revision: 4)
        let newer = stamp(ctx, Self.brussels, day: 20, by: semester, revision: 3)
        try ctx.save()

        #expect(await reconcile(await makeClassifier(container), semester)
                == .deferred(stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 0))
        let waiting = try stored(newer.id, container)
        #expect(waiting.temporaryHomeID == semester)
        #expect(waiting.temporaryHomeRevision == 3)
    }

    @Test("removal is terminal: a removed temporary home frees its stamps whatever their revision, hands one another temporary home claims to it, and leaves a protected trip's stamp")
    func removalReleasesNewerStamps() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let removed = temporaryHome(ctx, from: 10, revision: 6)
        removed.removedAt = date(60)
        let removedID = removed.id
        let heir = temporaryHome(ctx, from: 21, revision: 2).id
        let freed = stamp(ctx, Self.brussels, day: 20, by: removedID, revision: 9)
        let handed = stamp(ctx, Self.brussels, day: 25, by: removedID, revision: 9)
        let protected = stamp(ctx, Self.outing, day: 30, by: removedID, revision: 9)
        let side = stay(ctx, Self.outing, day: 31, .destination)
        let beringen = trip(ctx, [protected, side])
        ctx.insert(HiddenPhoto(localIdentifier: "photo", tripID: beringen.id))
        try ctx.save()

        #expect(await reconcile(await makeClassifier(container), removedID)
                == .committed(stamped: 0, freed: 1, rebuiltTrips: 0, protectedTrips: 0))
        let released = try stored(freed.id, container)
        #expect(released.category == .unclassified)
        #expect(released.temporaryHomeRevision == nil)
        let inherited = try stored(handed.id, container)
        #expect(inherited.category == .home)
        #expect(inherited.temporaryHomeID == heir)
        #expect(inherited.temporaryHomeRevision == 2)
        let kept = try stored(protected.id, container)
        #expect(kept.category == .home)
        #expect(kept.temporaryHomeID == removedID)
    }

    // MARK: - The losing branch

    @Test("a newer copy's stamp that waited a whole day is released by reissuing the winning copy above every revision seen, on every row, its place and dates unchanged")
    func losingBranchIsReissuedAfterADay() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        // The End that won at revision 5, and a losing twin at 4 with a later end.
        let winner = temporaryHome(ctx, until: 30, revision: 5, modifiedDay: 120)
        let id = winner.id
        let loser = temporaryHome(ctx, until: 60, revision: 4, modifiedDay: 110)
        loser.id = id
        // Stamped by the other device's revision 6, which lost.
        let late = stamp(ctx, Self.brussels, day: 40, by: id, revision: 6)
        try ctx.save()
        let now = Date.now
        let classifier = await makeClassifier(container)

        // Not a day yet: still deferred, nothing written.
        #expect(await reconcile(classifier, id, deferredSince: now.addingTimeInterval(-23 * 3600), now: now)
                == .deferred(stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 0))
        #expect(try declarationRows(id, container).map(\.coverageRevision).sorted() == [4, 5])
        #expect(try stored(late.id, container).category == .home)

        #expect(await reconcile(classifier, id, deferredSince: now.addingTimeInterval(-25 * 3600), now: now)
                == .committed(stamped: 0, freed: 1, rebuiltTrips: 0, protectedTrips: 0))
        let rows = try declarationRows(id, container)
        #expect(rows.count == 2)
        for row in rows {
            #expect(row.coverageRevision == 7)
            #expect(row.startedAt == date(10))
            #expect(row.endedAt == date(30))
            #expect(row.latitude == Self.brussels.lat && row.longitude == Self.brussels.lon)
            #expect(row.modifiedAt >= now)
        }
        let released = try stored(late.id, container)
        #expect(released.category == .unclassified)
        #expect(released.temporaryHomeID == nil)
    }

    @Test("deferred work keeps its debt and its first deferral's time across drains and a restart, waits while nothing changes, runs when the newer copy arrives, and is reissued once the day has passed",
          arguments: [false, true])
    func deferredDebtWaitsThenSettles(dayPasses: Bool) async throws {
        let scratch = try scratch()
        defer { cleanUp(scratch) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let id = temporaryHome(ctx, until: 30, revision: 1).id
        let late = stamp(ctx, Self.brussels, day: 40, by: id, revision: 2)
        try ctx.save()
        let log = SyncDrainLog()

        // First sight: the unit defers, its debt stays.
        #expect(await Self.drain(await makeClassifier(container), container,
                                 defaults: scratch.defaults, directory: scratch.directory, log: log)
                == false)
        #expect(log.events == ["temporary"])
        #expect(owed(scratch.defaults) == [id])
        let deferred = try #require(Acknowledgements.load(from: scratch.directory)[id])
        let since = try #require(deferred.deferredSince)
        #expect(try stored(late.id, container).category == .home)

        // Nothing changed: no unit, even after a restart (a new classifier).
        log.events = []
        #expect(await Self.drain(await makeClassifier(container), container,
                                 defaults: scratch.defaults, directory: scratch.directory, log: log)
                == false)
        #expect(log.events.isEmpty)
        #expect(owed(scratch.defaults) == [id])
        #expect(Acknowledgements.load(from: scratch.directory)[id]?.deferredSince == since)

        if dayPasses {
            // The first deferral was a day and an hour ago.
            try Acknowledgements.clear(in: scratch.directory)
            Acknowledgements.record(
                id, digest: deferred.digest, deferred: true,
                at: Date.now.addingTimeInterval(-25 * 3600), in: scratch.directory)
            #expect(await Self.drain(await makeClassifier(container), container,
                                     defaults: scratch.defaults, directory: scratch.directory, log: log))
            #expect(log.events == ["temporary"])
            #expect(try declarationRows(id, container).map(\.coverageRevision) == [3])
            #expect(try stored(late.id, container).category != .home)
        } else {
            // The newer copy arrives: its end and revision.
            try editRows(id, container) {
                $0.endedAt = self.date(100)
                $0.coverageRevision = 2
            }
            #expect(await Self.drain(await makeClassifier(container), container,
                                     defaults: scratch.defaults, directory: scratch.directory, log: log))
            #expect(log.events == ["temporary"])
            let home = try stored(late.id, container)
            #expect(home.category == .home)
            #expect(home.temporaryHomeRevision == 2)
        }
        #expect(owed(scratch.defaults).isEmpty)
        #expect(Acknowledgements.load(from: scratch.directory)[id]?.deferredSince == nil)
    }

    // MARK: - Arrival order

    enum Arrival: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case declarationFirst, stampFirst
        var testDescription: String { rawValue }
    }

    @Test("an older copy's stamp ends up freed whether it or the newer End arrives first",
          arguments: Arrival.allCases)
    func olderStampIsFreedInEitherOrder(arrival: Arrival) async throws {
        let scratch = try scratch()
        defer { cleanUp(scratch) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let id = arrival == .declarationFirst
            ? temporaryHome(ctx, until: 30, revision: 2).id
            : temporaryHome(ctx, revision: 1).id
        try ctx.save()
        let classifier = await makeClassifier(container)
        let log = SyncDrainLog()
        func drain() async {
            await Self.drain(classifier, container, defaults: scratch.defaults,
                             directory: scratch.directory, log: log)
        }
        await drain()
        func arriveStamp() throws -> UUID {
            let synced = ModelContext(container)
            let row = stamp(synced, Self.brussels, day: 40, by: id, revision: 1)
            try synced.save()
            return row.id
        }
        func arriveEnd() throws {
            try editRows(id, container) {
                $0.endedAt = self.date(30)
                $0.coverageRevision = 2
            }
        }
        let stampID: UUID
        switch arrival {
        case .declarationFirst:
            stampID = try arriveStamp()
            await drain()
        case .stampFirst:
            stampID = try arriveStamp()
            await drain()
            try arriveEnd()
            await drain()
        }
        let freed = try stored(stampID, container)
        #expect(freed.category != .home)
        #expect(freed.temporaryHomeID == nil)
        #expect(owed(scratch.defaults).isEmpty)
    }

    @Test("a newer copy's stamp stays home whether it or the newer copy arrives first: the older copy defers it instead of freeing it",
          arguments: Arrival.allCases)
    func newerStampStaysHomeInEitherOrder(arrival: Arrival) async throws {
        let scratch = try scratch()
        defer { cleanUp(scratch) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let id = arrival == .declarationFirst
            ? temporaryHome(ctx, until: 100, revision: 2).id
            : temporaryHome(ctx, until: 30, revision: 1).id
        try ctx.save()
        let classifier = await makeClassifier(container)
        let log = SyncDrainLog()
        func drain() async {
            await Self.drain(classifier, container, defaults: scratch.defaults,
                             directory: scratch.directory, log: log)
        }
        await drain()
        let synced = ModelContext(container)
        let stampID = stamp(synced, Self.brussels, day: 40, by: id, revision: 2).id
        try synced.save()
        await drain()
        // Never freed in between.
        #expect(try stored(stampID, container).category == .home)
        if arrival == .stampFirst {
            #expect(owed(scratch.defaults) == [id])
            try editRows(id, container) {
                $0.endedAt = self.date(100)
                $0.coverageRevision = 2
            }
            await drain()
        }
        let home = try stored(stampID, container)
        #expect(home.category == .home)
        #expect(home.temporaryHomeID == id)
        #expect(home.temporaryHomeRevision == 2)
        #expect(owed(scratch.defaults).isEmpty)
    }

    @Test("a copy that wins with new dates at the same revision is discovered and acted on: a stamp at that revision is freed")
    func sameRevisionContentChangeIsDiscovered() async throws {
        let scratch = try scratch()
        defer { cleanUp(scratch) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let id = temporaryHome(ctx, revision: 3).id
        let base = stay(ctx, Self.brussels, day: 25)
        try ctx.save()
        let classifier = await makeClassifier(container)
        await ordinaryPass(classifier)
        #expect(try stored(base.id, container).temporaryHomeRevision == 3)
        let log = SyncDrainLog()
        await Self.drain(classifier, container, defaults: scratch.defaults,
                         directory: scratch.directory, log: log)
        log.events = []

        try editRows(id, container) { $0.endedAt = self.date(20) }
        #expect(await Self.drain(classifier, container, defaults: scratch.defaults,
                                 directory: scratch.directory, log: log))
        #expect(log.events == ["temporary"])
        let freed = try stored(base.id, container)
        #expect(freed.category != .home)
        #expect(freed.temporaryHomeID == nil)
    }

    // MARK: - Discovery

    @Test("a trip another device classified and curated at the base, arriving after this device reconciled, is discovered and split: its stays become home")
    func lateClassifiedTripIsDiscovered() async throws {
        let scratch = try scratch()
        defer { cleanUp(scratch) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let id = temporaryHome(ctx).id
        try ctx.save()
        let classifier = await makeClassifier(container)
        let log = SyncDrainLog()
        #expect(await Self.drain(classifier, container, defaults: scratch.defaults,
                                 directory: scratch.directory, log: log))
        #expect(log.events == ["temporary"])
        log.events = []

        let synced = ModelContext(container)
        let first = stay(synced, Self.brussels, day: 20, days: 2, .destination)
        let second = stay(synced, Self.brussels, day: 23, days: 2, .destination)
        let curated = trip(synced, [first, second], name: "Settling in")
        try synced.save()
        let curatedID = curated.id

        #expect(await Self.drain(classifier, container, defaults: scratch.defaults,
                                 directory: scratch.directory, log: log))
        #expect(log.events == ["temporary"])
        for member in [first.id, second.id] {
            let row = try stored(member, container)
            #expect(row.category == .home)
            #expect(row.temporaryHomeID == id)
            #expect(row.temporaryHomeRevision == 1)
        }
        #expect(try !trips(container).contains { $0.id == curatedID })
    }

    @Test("a home stay at the base that arrives on a trip is discovered, and the trip is rebuilt around it")
    func linkedHomeStayIsDiscovered() async throws {
        let scratch = try scratch()
        defer { cleanUp(scratch) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let id = temporaryHome(ctx).id
        try ctx.save()
        let classifier = await makeClassifier(container)
        let log = SyncDrainLog()
        await Self.drain(classifier, container, defaults: scratch.defaults,
                         directory: scratch.directory, log: log)
        log.events = []

        let synced = ModelContext(container)
        let base = stamp(synced, Self.brussels, day: 20, by: id, revision: 1)
        let away = stay(synced, Self.outing, day: 21, .destination)
        trip(synced, [base, away])
        try synced.save()

        #expect(await Self.drain(classifier, container, defaults: scratch.defaults,
                                 directory: scratch.directory, log: log))
        #expect(log.events == ["temporary"])
        let home = try stored(base.id, container)
        #expect(home.category == .home)
        #expect(home.trip == nil)
    }

    @Test("what a unit leaves on purpose (a protected trip's stamp outside the dates, a kept trip's stay inside them) is acknowledged and not reconciled again until something changes")
    func unchangedResidueIsNotRestaged() async throws {
        let scratch = try scratch()
        defer { cleanUp(scratch) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let declaration = temporaryHome(ctx, until: 30)
        let id = declaration.id
        let outside = stamp(ctx, Self.brussels, day: 40, by: id, revision: 1)
        let side = stay(ctx, Self.outing, day: 41, .destination)
        let lastWeeks = trip(ctx, [outside, side])
        ctx.insert(HiddenPhoto(localIdentifier: "photo", tripID: lastWeeks.id))
        let inside = stay(ctx, Self.brussels, day: 20, days: 2, .destination)
        let keptTrip = trip(ctx, [inside], name: "Kept")
        declaration.addKeptTrip(keptTrip.id)
        try ctx.save()
        let classifier = await makeClassifier(container)
        let log = SyncDrainLog()

        #expect(await Self.drain(classifier, container, defaults: scratch.defaults,
                                 directory: scratch.directory, log: log))
        #expect(log.events == ["temporary"])
        #expect(try stored(outside.id, container).category == .home)
        #expect(try stored(inside.id, container).category == .destination)
        let acknowledged = try #require(Acknowledgements.load(from: scratch.directory)[id])
        #expect(await classifier.temporaryHomeDiscoveryDigests()?[id] == acknowledged.digest)

        log.events = []
        #expect(await Self.drain(classifier, container, defaults: scratch.defaults,
                                 directory: scratch.directory, log: log))
        #expect(log.events.isEmpty)
        #expect(owed(scratch.defaults).isEmpty)
    }

    @Test("a kept trip or a new place name synced in on its own is discovered: each runs the unit once")
    func keepAndLocalityChangesAreDiscovered() async throws {
        let scratch = try scratch()
        defer { cleanUp(scratch) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let id = temporaryHome(ctx).id
        try ctx.save()
        let classifier = await makeClassifier(container)
        let log = SyncDrainLog()
        func drain() async -> [String] {
            log.events = []
            await Self.drain(classifier, container, defaults: scratch.defaults,
                             directory: scratch.directory, log: log)
            return log.events
        }
        #expect(await drain() == ["temporary"])
        #expect(await drain().isEmpty)
        try editRows(id, container) { $0.addKeptTrip(UUID()) }
        #expect(await drain() == ["temporary"])
        #expect(await drain().isEmpty)
        try editRows(id, container) { $0.locality = "Bruxelles" }
        #expect(await drain() == ["temporary"])
        #expect(await drain().isEmpty)
    }

    @Test("a unit acknowledges exactly what it processed: a stay that arrives right after its commit is not acknowledged and is reconciled by the next drain")
    func acknowledgementIsExactlyWhatTheUnitProcessed() async throws {
        let scratch = try scratch()
        defer { cleanUp(scratch) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let id = temporaryHome(ctx).id
        try ctx.save()
        let classifier = await makeClassifier(container)
        let arrived = UUID()

        let outcome = await StayClassificationInference.TestHook.$availability.withValue(false) {
            await classifier.applyTemporaryHomeChange(
                temporaryHomeID: id, pinnedTripIDs: { [] },
                gate: PipelineGate(forTesting: ()), unpinRetired: { _ in },
                acknowledgementDirectory: scratch.directory,
                onSettled: {
                    // Another device's classified stay at the base lands now.
                    let synced = ModelContext(container)
                    let row = Stay(
                        startTime: Date(timeIntervalSinceReferenceDate: (22 + Self.dayZero) * 86_400),
                        endTime: Date(timeIntervalSinceReferenceDate: (22.8 + Self.dayZero) * 86_400),
                        centroidLatitude: 50.85, centroidLongitude: 4.35,
                        h3IndexRes6: "P", pingCount: 2, distanceFromHomeKm: 0, pingIDs: [],
                        source: .liveSLC, timeZoneIdentifier: "GMT")
                    row.id = arrived
                    row.category = .destination
                    synced.insert(row)
                    try? synced.save()
                })
        }
        #expect(outcome.isSettled)
        let acknowledged = try #require(Acknowledgements.load(from: scratch.directory)[id])
        #expect(await classifier.temporaryHomeDiscoveryDigests()?[id] != acknowledged.digest)

        let log = SyncDrainLog()
        #expect(await Self.drain(classifier, container, defaults: scratch.defaults,
                                 directory: scratch.directory, log: log))
        #expect(log.events == ["temporary"])
        let late = try stored(arrived, container)
        #expect(late.category == .home)
        #expect(late.temporaryHomeID == id)
    }

    @Test("a unit that stamps, frees and rebuilds leaves exactly what it acknowledges, so the next drain finds nothing to do")
    func committedWorkIsAcknowledgedAsLeft() async throws {
        let scratch = try scratch()
        defer { cleanUp(scratch) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let id = temporaryHome(ctx, until: 60).id
        let atBase = stay(ctx, Self.brussels, day: 20, days: 2, .destination)
        let away = stay(ctx, Self.outing, day: 23, .destination)
        trip(ctx, [atBase, away])
        let afterEnd = stamp(ctx, Self.brussels, day: 70, by: id, revision: 1)
        try ctx.save()
        let classifier = await makeClassifier(container)
        let log = SyncDrainLog()

        #expect(await Self.drain(classifier, container, defaults: scratch.defaults,
                                 directory: scratch.directory, log: log))
        #expect(log.events == ["temporary"])
        #expect(try stored(atBase.id, container).category == .home)
        #expect(try stored(afterEnd.id, container).category != .home)
        let acknowledged = try #require(Acknowledgements.load(from: scratch.directory)[id])
        #expect(acknowledged.deferredSince == nil)
        #expect(await classifier.temporaryHomeDiscoveryDigests()?[id] == acknowledged.digest)

        log.events = []
        #expect(await Self.drain(classifier, container, defaults: scratch.defaults,
                                 directory: scratch.directory, log: log))
        #expect(log.events.isEmpty)
    }

    // MARK: - Receiving-device maintenance ordering

    /// The order the receiving device runs its maintenance in.
    enum ReceivingOrder: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// Drain, heal, one ordinary pass.
        case drainHealPass
        /// What AppDelegate and RootView run after a remote change: the push's
        /// coalesced maintenance heals, the completed import's maintenance
        /// heals, the next activation drains then heals, then a pass.
        case pushImportActivationPass
        var testDescription: String { rawValue }
    }

    /// Athens, an open Brussels declaration from day 10, Brussels stays on days
    /// 20 and 40 made home by this device's ordinary pass, and a steady-state
    /// healing check.
    private func c1Store(defaults: UserDefaults) async throws -> (
        container: ModelContainer, classifier: TripClassifier,
        semesterID: UUID, duringID: UUID, afterEndID: UUID
    ) {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let semester = temporaryHome(ctx, revision: 0)
        let during = stay(ctx, Self.brussels, day: 20)
        let afterEnd = stay(ctx, Self.brussels, day: 40)
        try ctx.save()
        let ids = (semester.id, during.id, afterEnd.id)

        let classifier = await makeClassifier(container)
        await ordinaryPass(classifier)
        for id in [ids.1, ids.2] {
            let row = try stored(id, container)
            try #require(row.category == .home)
            try #require(row.temporaryHomeID == ids.0)
        }
        try #require(await Self.heal(classifier, defaults: defaults))
        return (container, classifier, ids.0, ids.1, ids.2)
    }

    @Test("a declaration ended on another device frees this device's later home stays it no longer covers",
          arguments: ReceivingOrder.allCases)
    func C1_remoteEndFreesLaterHomeStays(order: ReceivingOrder) async throws {
        let scratch = try scratch()
        defer { cleanUp(scratch) }
        let defaults = scratch.defaults
        let store = try await c1Store(defaults: defaults)

        // Another device ended it on day 30 before this device's day-40 stay
        // reached it; the synced row lands here with no save worker.
        try editRows(store.semesterID, store.container) { $0.endedAt = self.date(30) }
        #expect(CoverageReconciliationQueue.pending(defaults: defaults).isEmpty)

        let log = SyncDrainLog()
        let classifier = store.classifier
        func drain() async {
            await Self.drain(classifier, store.container, defaults: defaults,
                             directory: scratch.directory, log: log,
                             heal: { await Self.heal(classifier, defaults: defaults) })
        }
        switch order {
        case .drainHealPass:
            await drain()
            await Self.heal(classifier, defaults: defaults)
            await ordinaryPass(classifier)
        case .pushImportActivationPass:
            await Self.heal(classifier, defaults: defaults)
            await Self.heal(classifier, defaults: defaults)
            await drain()
            await Self.heal(classifier, defaults: defaults)
            await ordinaryPass(classifier)
        }

        let late = try stored(store.afterEndID, store.container)
        #expect(late.category != .home, "day-40 stay still \(late.category); drain events: \(log.events)")
        #expect(late.temporaryHomeID == nil)
        // The stay inside the remaining dates stays home.
        let during = try stored(store.duringID, store.container)
        #expect(during.category == .home)
        #expect(during.temporaryHomeID == store.semesterID)
        #expect(log.events.contains("temporary"),
                "the drain found no temporary-home work; events: \(log.events)")
    }

    @Test("the same end saved on this device (queued by the save worker) frees the day-40 stay through the same drain")
    func C1_control_localEndFreesLaterHomeStays() async throws {
        let scratch = try scratch()
        defer { cleanUp(scratch) }
        let store = try await c1Store(defaults: scratch.defaults)

        _ = CoverageReconciliationQueue.stage(.temporaryHome, id: store.semesterID, defaults: scratch.defaults)
        try editRows(store.semesterID, store.container) { $0.endedAt = self.date(30) }

        let log = SyncDrainLog()
        #expect(await Self.drain(store.classifier, store.container, defaults: scratch.defaults,
                                 directory: scratch.directory, log: log))
        await ordinaryPass(store.classifier)

        #expect(log.events.first == "temporary")
        let late = try stored(store.afterEndID, store.container)
        #expect(late.category != .home)
        #expect(late.temporaryHomeID == nil)
        let during = try stored(store.duringID, store.container)
        #expect(during.category == .home)
        #expect(during.temporaryHomeID == store.semesterID)
    }

    @Test("the other device's day-40 home stay, stamped before it saw the end, syncs in after this device reconciled its own end, and is freed")
    func C1_deviceA_lateSyncedStampIsFreed() async throws {
        let scratch = try scratch()
        defer { cleanUp(scratch) }
        let defaults = scratch.defaults
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let semesterID = temporaryHome(ctx, revision: 0).id
        let during = stay(ctx, Self.brussels, day: 20)
        try ctx.save()
        let classifier = await makeClassifier(container)
        await ordinaryPass(classifier)
        try #require(try stored(during.id, container).temporaryHomeID == semesterID)
        try #require(await Self.heal(classifier, defaults: defaults))

        // This device ends it on day 30 through the save worker's queue.
        _ = CoverageReconciliationQueue.stage(.temporaryHome, id: semesterID, defaults: defaults)
        try editRows(semesterID, container) { $0.endedAt = self.date(30) }
        let log = SyncDrainLog()
        func drain() async -> Bool {
            await Self.drain(classifier, container, defaults: defaults,
                             directory: scratch.directory, log: log,
                             heal: { await Self.heal(classifier, defaults: defaults) })
        }
        try #require(await drain())
        await ordinaryPass(classifier)

        // The other device's day-40 stay arrives as it stamped it there.
        let synced = ModelContext(container)
        let late = stamp(synced, Self.brussels, day: 40, by: semesterID, revision: nil)
        try synced.save()
        let lateID = late.id

        // Push, completed import, activation, then a pass.
        log.events = []
        await Self.heal(classifier, defaults: defaults)
        await Self.heal(classifier, defaults: defaults)
        _ = await drain()
        await Self.heal(classifier, defaults: defaults)
        await ordinaryPass(classifier)

        let row = try stored(lateID, container)
        #expect(row.category != .home,
                "synced day-40 stay still \(row.category); drain events: \(log.events)")
        #expect(row.temporaryHomeID == nil)
    }

    // MARK: - Drain turns

    /// Stages that log the temporary-home unit they run under `name` and settle it.
    private static func loggingStages(
        _ name: String, log: SyncDrainLog,
        discovery: @escaping @MainActor @Sendable () async -> [UUID: String]?
    ) -> CoverageReconciliationQueue.Stages {
        CoverageReconciliationQueue.Stages(
            applyHome: { _, _ in .failed },
            applyRoutinePlace: { _, _ in .failed },
            applyTemporaryHome: { _, onSettled in
                log.events.append(name)
                onSettled()
                return .committed(stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 0)
            },
            generateLocalizedTitles: {},
            publish: { _, _ in },
            publishTemporaryHomes: {},
            heal: {},
            isPersistentStore: { true },
            discoveryDigests: discovery)
    }

    @Test("a drain waiting on its discovery read holds no turn: a drain started meanwhile runs its work, and the first then runs its own")
    func discoveryReadHoldsNoTurn() async throws {
        let first = try scratch(), second = try scratch()
        defer {
            cleanUp(first)
            cleanUp(second)
        }
        CoverageReconciliationQueue.enqueue(.temporaryHome, id: UUID(), defaults: first.defaults)
        CoverageReconciliationQueue.enqueue(.temporaryHome, id: UUID(), defaults: second.defaults)
        let log = SyncDrainLog()
        let otherDefaults = second.defaults
        let outer = Self.loggingStages("first", log: log, discovery: {
            log.events.append("reading")
            let inner = Self.loggingStages("second", log: log, discovery: { [:] })
            #expect(await CoverageReconciliationQueue.drainIfNeeded(
                defaults: otherDefaults, stages: inner))
            return [:]
        })

        #expect(await CoverageReconciliationQueue.drainIfNeeded(defaults: first.defaults, stages: outer))
        #expect(log.events == ["reading", "second", "first"])
        #expect(owed(first.defaults).isEmpty)
        #expect(owed(second.defaults).isEmpty)
    }

    // MARK: - Acknowledgement store

    @Test("the acknowledgement file keeps the first deferral's time while units keep deferring, drops it when one does not, reads as empty when unreadable, and clears")
    func acknowledgementsKeepTheFirstDeferral() throws {
        let scratch = try scratch()
        defer { cleanUp(scratch) }
        let id = UUID(), other = UUID()
        let first = Date(timeIntervalSinceReferenceDate: 1_000)
        Acknowledgements.record(id, digest: "a", deferred: true, at: first, in: scratch.directory)
        Acknowledgements.record(id, digest: "b", deferred: true,
                                at: first.addingTimeInterval(60), in: scratch.directory)
        Acknowledgements.record(other, digest: "c", deferred: false, at: first, in: scratch.directory)
        var entries = Acknowledgements.load(from: scratch.directory)
        #expect(entries[id] == .init(digest: "b", at: first.addingTimeInterval(60), deferredSince: first))
        #expect(entries[other] == .init(digest: "c", at: first, deferredSince: nil))

        Acknowledgements.record(id, digest: "d", deferred: false,
                                at: first.addingTimeInterval(120), in: scratch.directory)
        entries = Acknowledgements.load(from: scratch.directory)
        #expect(entries[id]?.deferredSince == nil)

        let url = try #require(Acknowledgements.fileURL(in: scratch.directory))
        try Data("not json".utf8).write(to: url)
        #expect(Acknowledgements.load(from: scratch.directory).isEmpty)
        try Acknowledgements.clear(in: scratch.directory)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try Acknowledgements.clear(in: scratch.directory)
    }

    // MARK: - trips covered through home evidence

    @Test("an edited trip that arrives after the base stay was acknowledged, away on both sides of that tripless stay and never at the base itself, is discovered and split there")
    func lateTripSpanningTheBaseIsDiscovered() async throws {
        let scratch = try scratch()
        defer { cleanUp(scratch) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let id = temporaryHome(ctx).id
        let base = stamp(ctx, Self.brussels, day: 20, by: id, revision: 1)
        try ctx.save()
        let classifier = await makeClassifier(container)
        let log = SyncDrainLog()
        #expect(await Self.drain(classifier, container, defaults: scratch.defaults,
                                 directory: scratch.directory, log: log))
        #expect(log.events == ["temporary"])
        log.events = []

        // Another device's named trip, away on days 15 and 25.
        let synced = ModelContext(container)
        let before = stay(synced, Self.outing, day: 15, .destination)
        let after = stay(synced, Self.outing, day: 25, .destination)
        let curated = trip(synced, [before, after], name: "Benelux loop")
        try synced.save()
        let curatedID = curated.id

        #expect(await Self.drain(classifier, container, defaults: scratch.defaults,
                                 directory: scratch.directory, log: log))
        #expect(log.events == ["temporary"])
        #expect(try !trips(container).contains { $0.id == curatedID })
        for member in [before.id, after.id] {
            #expect(try stored(member, container).trip?.id != curatedID)
        }
        let home = try stored(base.id, container)
        #expect(home.category == .home)
        #expect(home.trip == nil)
        #expect(home.temporaryHomeID == id)

        // What the split left is acknowledged.
        log.events = []
        #expect(await Self.drain(classifier, container, defaults: scratch.defaults,
                                 directory: scratch.directory, log: log))
        #expect(log.events.isEmpty)
    }

    // MARK: - rebuilt and kept trips' stamps

    /// Whose stamp a unit for the semester (ended on day 30 at revision 1) meets.
    enum ForeignStamp: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// The semester's own, from a newer copy at revision 2.
        case newerCopy
        /// Another live declaration's, at Brussels from day 38.
        case otherDeclaration
        var testDescription: String { rawValue }
    }

    @Test("a home stay on a trip the covering rebuilds keeps its category and pair when the unit may not release it; a newer copy's stamp defers the unit and settles once that copy arrives",
          arguments: ForeignStamp.allCases)
    func rebuiltTripKeepsStampsItMayNotRelease(stamp foreign: ForeignStamp) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let id = temporaryHome(ctx, until: 30, revision: 1).id
        let owner = foreign == .newerCopy ? id : temporaryHome(ctx, from: 38, revision: 1).id
        let revision = foreign == .newerCopy ? 2 : 3
        // A synced, untouched trip: a destination at the base, then a home stay after the end.
        let atBase = stay(ctx, Self.brussels, day: 20, .destination)
        let later = stamp(ctx, Self.brussels, day: 40, by: owner, revision: revision)
        trip(ctx, [atBase, later])
        try ctx.save()
        let classifier = await makeClassifier(container)

        let outcome = await reconcile(classifier, id)
        #expect(outcome.didCommit)
        #expect(outcome.isSettled == (foreign == .otherDeclaration))
        #expect(try stored(atBase.id, container).category == .home)
        let held = try stored(later.id, container)
        #expect(held.category == .home)
        #expect(held.temporaryHomeID == owner)
        #expect(held.temporaryHomeRevision == revision)

        guard foreign == .newerCopy else { return }
        try editRows(id, container) {
            $0.endedAt = self.date(100)
            $0.coverageRevision = 2
        }
        #expect(await reconcile(classifier, id).isSettled)
        let settled = try stored(later.id, container)
        #expect(settled.category == .home)
        #expect(settled.temporaryHomeID == id)
        #expect(settled.temporaryHomeRevision == 2)
    }

    @Test("an edited trip's member stamped by a declaration is settled only under the unit's authority: a newer copy's stamp and another live declaration's stay home with their pairs on the trip, and the newer copy's settles once it arrives",
          arguments: ForeignStamp.allCases)
    func editedTripKeepsStampsItMayNotRelease(stamp foreign: ForeignStamp) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let id = temporaryHome(ctx, until: 30, revision: 1).id
        let owner = foreign == .newerCopy ? id : temporaryHome(ctx, from: 38, revision: 1).id
        let revision = foreign == .newerCopy ? 2 : 3
        let away = stay(ctx, Self.outing, day: 35, .destination)
        let later = stamp(ctx, Self.brussels, day: 40, by: owner, revision: revision)
        let edited = trip(ctx, [away, later], name: "Last weeks")
        let editedID = edited.id
        try ctx.save()
        let classifier = await makeClassifier(container)

        let outcome = await reconcile(classifier, id)
        #expect(outcome.didCommit)
        #expect(outcome.isSettled == (foreign == .otherDeclaration))
        let held = try stored(later.id, container)
        #expect(held.category == .home)
        #expect(held.temporaryHomeID == owner)
        #expect(held.temporaryHomeRevision == revision)
        #expect(held.trip?.id == editedID)

        guard foreign == .newerCopy else { return }
        try editRows(id, container) {
            $0.endedAt = self.date(100)
            $0.coverageRevision = 2
        }
        #expect(await reconcile(classifier, id).isSettled)
        let settled = try stored(later.id, container)
        #expect(settled.category == .home)
        #expect(settled.temporaryHomeID == id)
        #expect(settled.temporaryHomeRevision == 2)
    }

    @Test("an explicitly kept trip's member is settled whatever its stamp's revision; Keep authorizes it")
    func explicitKeepSettlesItsMembersWhateverTheRevision() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let declaration = temporaryHome(ctx, until: 30, revision: 1)
        let id = declaration.id
        let away = stay(ctx, Self.outing, day: 35, .destination)
        let later = stamp(ctx, Self.brussels, day: 40, by: id, revision: 2)
        let kept = trip(ctx, [away, later], name: "Kept")
        declaration.addKeptTrip(kept.id)
        let keptID = kept.id
        try ctx.save()

        #expect(await reconcile(await makeClassifier(container), id).isSettled)
        let settled = try stored(later.id, container)
        #expect(settled.category != .home)
        #expect(settled.temporaryHomeID == nil)
        #expect(settled.temporaryHomeRevision == nil)
        #expect(settled.trip?.id == keptID)
    }

    // MARK: - automatic healing

    @Test("healing's shrink repair leaves a newer copy's stamp that the drain's deferring unit just left, so the stay stays home with its pair until the newer copy arrives or the day passes",
          arguments: [false, true])
    func healingKeepsADeferredStamp(dayPasses: Bool) async throws {
        let scratch = try scratch()
        defer { cleanUp(scratch) }
        let defaults = scratch.defaults
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let id = temporaryHome(ctx, revision: 0).id
        // A commute spot 14 km north of the base, taught for the semester.
        let commute: Place = (50.98, 4.35)
        ctx.insert(HomeAreaOverride(kind: .include, centerLatitude: commute.lat,
                                    centerLongitude: commute.lon, radiusKm: 2, homeID: id))
        // Another device's copy at revision 2 stamped a day-40 commute stay.
        let late = stamp(ctx, commute, day: 40, by: id, revision: 2)
        try ctx.save()
        let classifier = await makeClassifier(container)
        // The include is in the healing snapshot, and the unit has seen the store.
        try #require(await Self.heal(classifier, defaults: defaults))
        let log = SyncDrainLog()
        func drain() async -> Bool {
            await Self.drain(classifier, container, defaults: defaults,
                             directory: scratch.directory, log: log,
                             heal: { await Self.heal(classifier, defaults: defaults) })
        }
        #expect(await drain())
        try #require(try stored(late.id, container).category == .home)

        // The End that won, at revision 1.
        try editRows(id, container) {
            $0.endedAt = self.date(30)
            $0.coverageRevision = 1
        }
        log.events = []
        #expect(await drain() == false)
        #expect(log.events == ["temporary"])
        #expect(owed(defaults) == [id])
        let waiting = try stored(late.id, container)
        #expect(waiting.category == .home)
        #expect(waiting.temporaryHomeID == id)
        #expect(waiting.temporaryHomeRevision == 2)
        // Another heal and pass leave it too.
        await Self.heal(classifier, defaults: defaults)
        await ordinaryPass(classifier)
        #expect(try stored(late.id, container).temporaryHomeRevision == 2)

        if dayPasses {
            let deferred = try #require(Acknowledgements.load(from: scratch.directory)[id])
            try Acknowledgements.clear(in: scratch.directory)
            Acknowledgements.record(
                id, digest: deferred.digest, deferred: true,
                at: Date.now.addingTimeInterval(-25 * 3600), in: scratch.directory)
            #expect(await drain())
            let freed = try stored(late.id, container)
            #expect(freed.category != .home)
            #expect(freed.temporaryHomeID == nil)
        } else {
            try editRows(id, container) {
                $0.endedAt = self.date(100)
                $0.coverageRevision = 2
            }
            #expect(await drain())
            let home = try stored(late.id, container)
            #expect(home.category == .home)
            #expect(home.temporaryHomeID == id)
            #expect(home.temporaryHomeRevision == 2)
        }
        #expect(owed(defaults).isEmpty)
    }

    @Test("a Home change's stale pass frees a temporary home's stamp only as that home's own unit may: a removed one's whatever its revision and a live one's at or below the copy here, never a newer copy's or one of a declaration this device does not hold")
    func homeChangeReleasesStampsByTheUnitsRules() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let live = temporaryHome(ctx, until: 30, revision: 2).id
        let removed = temporaryHome(ctx, revision: 1)
        removed.removedAt = date(60)
        // Stamps at the base after day 30: no ring claims any of them.
        let current = stamp(ctx, Self.brussels, day: 40, by: live, revision: 2)
        let newer = stamp(ctx, Self.brussels, day: 41, by: live, revision: 3)
        let ofRemoved = stamp(ctx, Self.brussels, day: 42, by: removed.id, revision: 5)
        let unknownOwner = UUID()
        let unknown = stamp(ctx, Self.brussels, day: 43, by: unknownOwner, revision: 1)
        try ctx.save()
        let homeID = try #require(try ModelContext(container).fetch(FetchDescriptor<Home>()).first).id

        #expect(await makeClassifier(container).applyHomeChangeCore(homeID: homeID).isSettled)
        for id in [current.id, ofRemoved.id] {
            let freed = try stored(id, container)
            #expect(freed.category != .home)
            #expect(freed.temporaryHomeID == nil)
        }
        let waiting = try stored(newer.id, container)
        #expect(waiting.category == .home)
        #expect(waiting.temporaryHomeID == live)
        #expect(waiting.temporaryHomeRevision == 3)
        let notHere = try stored(unknown.id, container)
        #expect(notHere.category == .home)
        #expect(notHere.temporaryHomeID == unknownOwner)
    }

    @Test("a Home change resetting the stays inside a former Home's area leaves a newer copy's stamp and one of a declaration this device does not hold as they are, category and pair, through the next pass; a current stamp there is judged again as before")
    func homeChangeAreaResetKeepsStampsItMayNotFree() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        // A real Home at the base long before the semester, ended since.
        let former = Home(label: "Brussels", latitude: Self.brussels.lat, longitude: Self.brussels.lon,
                          radiusKm: 25, startedAt: date(-500))
        former.endedAt = date(5)
        ctx.insert(former)
        let live = temporaryHome(ctx, until: 30, revision: 2).id
        let current = stamp(ctx, Self.brussels, day: 20, by: live, revision: 2)
        let newer = stamp(ctx, Self.brussels, day: 41, by: live, revision: 3)
        let unknownOwner = UUID()
        let unknown = stamp(ctx, Self.brussels, day: 43, by: unknownOwner, revision: 1)
        try ctx.save()
        let formerID = former.id

        let classifier = await makeClassifier(container)
        #expect(await classifier.applyHomeChangeCore(homeID: formerID).isSettled)
        // Day 20 is after the former Home's era (ended day 5), so its area
        // reset leaves the stay to the live temporary home that stamped it.
        #expect(try stored(current.id, container).category == .home)
        for step in ["after the change", "after the next pass"] {
            if step == "after the next pass" { await ordinaryPass(classifier) }
            let waiting = try stored(newer.id, container)
            #expect(waiting.category == .home, "\(step)")
            #expect(waiting.temporaryHomeID == live, "\(step)")
            #expect(waiting.temporaryHomeRevision == 3, "\(step)")
            let notHere = try stored(unknown.id, container)
            #expect(notHere.category == .home, "\(step)")
            #expect(notHere.temporaryHomeID == unknownOwner, "\(step)")
            #expect(notHere.temporaryHomeRevision == 1, "\(step)")
        }
        let rejudged = try stored(current.id, container)
        #expect(rejudged.category == .home)
        #expect(rejudged.temporaryHomeID == live)
        #expect(rejudged.temporaryHomeRevision == 2)
    }

    @Test("healing that dissolves a trip all of whose stays are home area leaves a newer copy's stamp and one of a declaration this device does not hold as they are, category and pair, through the next pass; its other stays are judged again as before")
    func healingDissolveKeepsStampsItMayNotFree() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let live = temporaryHome(ctx, until: 100, revision: 2).id
        let newer = stamp(ctx, Self.brussels, day: 41, by: live, revision: 3)
        let errand = stay(ctx, Self.athens, day: 45, .destination)
        let unknownOwner = UUID()
        let unknown = stamp(ctx, Self.athens, day: 46, by: unknownOwner, revision: 1)
        let claimed = trip(ctx, [newer, errand, unknown])
        let claimedID = claimed.id
        try ctx.save()

        let classifier = await makeClassifier(container)
        let outcome = await PipelineGate(forTesting: ()).runReturning(touching: [.stay, .trip]) {
            await classifier.healHomeAreaCorrections(pinnedTripIDs: [])
        }
        #expect(outcome == TripClassifier.HomeAreaHealingOutcome(moved: 1, failed: false))
        #expect(try trips(container).allSatisfy { $0.id != claimedID })
        #expect(try stored(errand.id, container).category == .unclassified)
        for step in ["after healing", "after the next pass"] {
            if step == "after the next pass" { await ordinaryPass(classifier) }
            let waiting = try stored(newer.id, container)
            #expect(waiting.category == .home, "\(step)")
            #expect(waiting.temporaryHomeID == live, "\(step)")
            #expect(waiting.temporaryHomeRevision == 3, "\(step)")
            let notHere = try stored(unknown.id, container)
            #expect(notHere.category == .home, "\(step)")
            #expect(notHere.temporaryHomeID == unknownOwner, "\(step)")
            #expect(notHere.temporaryHomeRevision == 1, "\(step)")
        }
        let rejudged = try stored(errand.id, container)
        #expect(rejudged.category == .home)
        #expect(rejudged.temporaryHomeID == nil)
    }

    // MARK: - the keep before the trip's own mark

    /// A trip the semester keeps whole, holding a stay at the base between
    /// two outings, and a later outing stay with no home between. The names
    /// are each stay's part in the fixture.
    private func seedKeptTrip(
        _ container: ModelContainer, complete: Bool, marked: Bool
    ) throws -> (trip: UUID, names: [UUID: String]) {
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let declaration = temporaryHome(ctx)
        let members = [stay(ctx, Self.outing, day: 12, .destination),
                       stamp(ctx, Self.brussels, day: 13, by: declaration.id, revision: 1),
                       stay(ctx, Self.outing, day: 16, .destination)]
        let kept = trip(ctx, members)
        if !complete {
            kept.isComplete = false
            kept.endDate = nil
        }
        if marked {
            kept.userEdited = true
            kept.keptByTemporaryHome = true
        }
        declaration.addKeptTrip(kept.id)
        let later = stay(ctx, Self.outing, day: 17, .destination)
        try ctx.save()
        return (kept.id, [members[0].id: "outing", members[1].id: "base",
                          members[2].id: "outing again", later.id: "later outing"])
    }

    /// Every trip as its stays' parts in order, the kept trip's marked as such.
    private func grouping(
        _ container: ModelContainer, kept: UUID, names: [UUID: String]
    ) throws -> Set<String> {
        Set(try trips(container).map { trip in
            (trip.id == kept ? "kept: " : "trip: ")
                + trip.orderedStays.map { names[$0.id] ?? "?" }.joined(separator: ", ")
        })
    }

    @Test("an ordinary pass leaves a trip a live declaration keeps exactly as it leaves the same trip once its edit mark has synced, open or completed: never taken apart at the stay at the base, its id and members kept",
          arguments: [false, true])
    func declarationKeepHoldsAnUnmarkedTrip(complete: Bool) async throws {
        var outcomes: [Bool: Set<String>] = [:]
        for marked in [false, true] {
            let container = try TestSupport.makeInMemoryContainer()
            let seeded = try seedKeptTrip(container, complete: complete, marked: marked)
            await ordinaryPass(await makeClassifier(container))
            let row = try #require(try trips(container).first { $0.id == seeded.trip })
            #expect(row.userEdited == marked, "marked: \(marked)")
            outcomes[marked] = try grouping(container, kept: seeded.trip, names: seeded.names)
        }
        #expect(outcomes[false] == outcomes[true])
        #expect(outcomes[false] == (complete
            ? ["kept: outing, base, outing again", "trip: later outing"]
            : ["kept: outing, base, outing again, later outing"]))
    }

    @Test("the keep union is a required read of every ordinary assembly: when it cannot be read the pass rolls back and changes nothing")
    func unreadableKeepUnionFailsAssembly() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        temporaryHome(ctx)
        trip(ctx, [stay(ctx, Self.outing, day: 12, .destination)])
        try ctx.save()
        let classifier = await makeClassifier(container)
        classifier.failTemporaryHomeReadForTesting = true
        defer { classifier.failTemporaryHomeReadForTesting = false }
        #expect(await classifier.assembleTrips() == -1)
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        classifier.failTemporaryHomeReadForTesting = false
        #expect(await classifier.assembleTrips() == 0)
    }

    // MARK: - protection in residue

    enum Protection: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case hiddenPhoto, favourite
        var testDescription: String { rawValue }
    }

    @Test("a stamp a unit left because its untouched trip was protected is discovered again once that protection goes, and freed",
          arguments: Protection.allCases)
    func removedProtectionReArmsDiscovery(protection: Protection) async throws {
        let scratch = try scratch()
        defer { cleanUp(scratch) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let id = temporaryHome(ctx, until: 30).id
        let outside = stamp(ctx, Self.brussels, day: 40, by: id, revision: 1)
        let side = stay(ctx, Self.outing, day: 41, .destination)
        let lastWeeks = trip(ctx, [outside, side])
        let tripID = lastWeeks.id
        let inputs = SyncInputs()
        switch protection {
        case .hiddenPhoto: ctx.insert(HiddenPhoto(localIdentifier: "photo", tripID: tripID))
        case .favourite: inputs.favourites = [tripID]
        }
        try ctx.save()
        let classifier = await makeClassifier(container)
        let log = SyncDrainLog()
        func drain() async -> [String] {
            log.events = []
            await Self.drain(classifier, container, defaults: scratch.defaults,
                             directory: scratch.directory, log: log,
                             favourites: { inputs.favourites })
            return log.events
        }
        #expect(await drain() == ["temporary"])
        #expect(try stored(outside.id, container).category == .home)
        #expect(await drain().isEmpty)

        switch protection {
        case .hiddenPhoto:
            let edit = ModelContext(container)
            for row in try edit.fetch(FetchDescriptor<HiddenPhoto>()) { edit.delete(row) }
            try edit.save()
        case .favourite:
            inputs.favourites = []
        }
        #expect(try trips(container).first { $0.id == tripID }?.userEdited == false)

        #expect(await drain() == ["temporary"])
        let freed = try stored(outside.id, container)
        #expect(freed.category != .home)
        #expect(freed.temporaryHomeID == nil)
        #expect(await drain().isEmpty)
    }

    // MARK: - discovery cost

    @Test("a drain whose store and favourites have not changed since the last discovery read, with no debt staged or settled since, does not read again; a late stay, a declaration change and a new debt each bring a read, and the read finds them")
    func unchangedDiscoveryIsNotReadAgain() async throws {
        let scratch = try scratch()
        defer { cleanUp(scratch) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let id = temporaryHome(ctx).id
        try ctx.save()
        let classifier = await makeClassifier(container)
        let inputs = SyncInputs()
        let throttle = CoverageReconciliationQueue.DiscoveryThrottle {
            .init(storeGeneration: inputs.generation, favourites: inputs.favourites)
        }
        let log = SyncDrainLog()
        func drain() async -> (reads: Int, units: [String]) {
            log.events = []
            let before = log.reads
            await Self.drain(classifier, container, defaults: scratch.defaults,
                             directory: scratch.directory, log: log,
                             favourites: { inputs.favourites }, throttle: throttle)
            return (log.reads - before, log.events)
        }
        #expect(await drain() == (1, ["temporary"]))
        // The settled debt brings one more read, which finds nothing new.
        #expect(await drain() == (1, []))
        #expect(await drain() == (0, []))
        #expect(await drain() == (0, []))

        // A stay at the base syncs in, and the push advances the store generation.
        let synced = ModelContext(container)
        let late = stay(synced, Self.brussels, day: 22, .destination)
        try synced.save()
        inputs.generation += 1
        #expect(await drain() == (1, ["temporary"]))
        #expect(try stored(late.id, container).category == .home)
        #expect(await drain() == (1, []))
        #expect(await drain() == (0, []))

        // A declaration change syncs in.
        try editRows(id, container) { $0.endedAt = self.date(21) }
        inputs.generation += 1
        #expect(await drain() == (1, ["temporary"]))
        #expect(try stored(late.id, container).category != .home)
        #expect(await drain() == (1, []))
        #expect(await drain() == (0, []))

        // A favourite changes nothing in the store but is read.
        inputs.favourites = [UUID()]
        #expect(await drain() == (1, []))
        #expect(await drain() == (0, []))

        // Debt staged by a save brings a read.
        CoverageReconciliationQueue.enqueue(.temporaryHome, id: id, defaults: scratch.defaults)
        #expect(await drain() == (1, ["temporary"]))
    }

    @Test("the throttle reads when it has no record, when the watermark is unknown or moved, when the debt changed, when the last read failed, and once the record is older than its lifetime; otherwise it answers with the last read")
    func discoveryThrottleRules() async throws {
        let box = SyncInputs()
        let throttle = CoverageReconciliationQueue.DiscoveryThrottle {
            box.generation < 0 ? nil : .init(storeGeneration: box.generation, favourites: box.favourites)
        }
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        var answer: [UUID: String]? = [UUID(): "a"]
        var reads = 0
        func ask(owed: Set<UUID> = [], at: Date) async -> [UUID: String]? {
            await throttle.digests(owed: owed, now: at) {
                reads += 1
                return answer
            }
        }
        let first = answer
        #expect(await ask(at: now) == first)
        #expect(reads == 1)
        answer = [UUID(): "b"]
        #expect(await ask(at: now.addingTimeInterval(60)) == first)
        #expect(reads == 1)
        // Moved.
        box.generation = 1
        #expect(await ask(at: now.addingTimeInterval(60)) == answer)
        #expect(reads == 2)
        // Unknown.
        box.generation = -1
        #expect(await ask(at: now.addingTimeInterval(60)) == answer)
        #expect(await ask(at: now.addingTimeInterval(60)) == answer)
        #expect(reads == 4)
        box.generation = 1
        _ = await ask(at: now.addingTimeInterval(60))
        #expect(reads == 5)
        // Debt changed.
        _ = await ask(owed: [UUID()], at: now.addingTimeInterval(60))
        #expect(reads == 6)
        // A failed read leaves no record.
        let lastOwed: Set<UUID> = [UUID()]
        answer = nil
        #expect(await ask(owed: lastOwed, at: now.addingTimeInterval(60)) == nil)
        answer = [UUID(): "c"]
        #expect(await ask(owed: lastOwed, at: now.addingTimeInterval(60)) == answer)
        #expect(reads == 8)
        #expect(await ask(owed: lastOwed, at: now.addingTimeInterval(120)) == answer)
        #expect(reads == 8)
        // Too old.
        let later = now.addingTimeInterval(
            60 + CoverageReconciliationQueue.DiscoveryThrottle.lifetime + 1)
        _ = await ask(owed: lastOwed, at: later)
        #expect(reads == 9)
        _ = await ask(owed: lastOwed, at: later)
        #expect(reads == 9)
        // A drain that ran a unit forgets the record.
        throttle.invalidate()
        _ = await ask(owed: lastOwed, at: later)
        #expect(reads == 10)
    }

    @Test("the live watermark is unknown while a write to a table discovery reads awaits its flush, moves once it lands, ignores tables discovery does not read, and carries the favourites")
    func liveWatermarkFollowsTheStoreTables() {
        let tracker = StoreChangeTracker(forTesting: ())
        typealias Throttle = CoverageReconciliationQueue.DiscoveryThrottle
        let start = Throttle.watermark(tracker: tracker, favourites: [])
        #expect(start != nil)
        tracker.bump(.stay)
        #expect(Throttle.watermark(tracker: tracker, favourites: []) == nil)
        tracker.flushPendingForTesting()
        let moved = Throttle.watermark(tracker: tracker, favourites: [])
        #expect(moved != nil && moved != start)
        tracker.applyNowForTesting(.yearWrapped)
        #expect(Throttle.watermark(tracker: tracker, favourites: []) == moved)
        for table: StoreChange in [.trip, .temporaryHome, .homeAreaOverride, .hiddenPhoto, .pinnedPhoto, .visit] {
            let before = Throttle.watermark(tracker: tracker, favourites: [])
            tracker.applyNowForTesting(table)
            #expect(Throttle.watermark(tracker: tracker, favourites: []) != before)
        }
        let favourite = UUID()
        #expect(Throttle.watermark(tracker: tracker, favourites: [favourite])?.favourites == [favourite])
    }

    @Test("discovery reads each declaration's own dates and area plus the stamped stays, not the months between declarations or other places, and still matches what the units acknowledged; late stays and declaration changes are found")
    func discoveryReadsEachDeclarationsWindowAndArea() async throws {
        let scratch = try scratch()
        defer { cleanUp(scratch) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let first = temporaryHome(ctx, from: 10, until: 40).id
        let second = temporaryHome(ctx, from: 250).id
        let tokyo: Place = (35.68, 139.69)
        // A year, every day somewhere: Athens, Tokyo, the outing, Brussels.
        for day in 1..<365 {
            let places: [Place] = [Self.athens, tokyo, Self.outing, Self.brussels]
            let place = places[day % places.count]
            stay(ctx, place, day: Double(day), days: 0.5,
                 place.lat == Self.athens.lat ? .home : .destination)
        }
        try ctx.save()
        let classifier = await makeClassifier(container)
        let log = SyncDrainLog()
        #expect(await Self.drain(classifier, container, defaults: scratch.defaults,
                                 directory: scratch.directory, log: log))
        #expect(Set(log.events) == ["temporary"])

        let digests = try #require(await classifier.temporaryHomeDiscoveryDigests())
        let acknowledged = Acknowledgements.load(from: scratch.directory)
        #expect(digests[first] == acknowledged[first]?.digest)
        #expect(digests[second] == acknowledged[second]?.digest)
        // Stamped stays, and the stays at Brussels inside either declaration's dates.
        let all = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        let stamped = all.filter { $0.category == .home && $0.temporaryHomeID != nil }.count
        let atBase = all.filter { stay in
            abs(stay.centroidLatitude - Self.brussels.lat) < 0.2
                && abs(stay.centroidLongitude - Self.brussels.lon) < 0.2
                && ((stay.startTime >= date(10) && stay.startTime <= date(40))
                    || stay.startTime >= date(250))
        }.count
        let read = await classifier.discoveryStayReadCountForTesting
        #expect(read <= stamped + atBase)
        #expect(read * 3 < all.count)

        // A late stay inside the first declaration, and a change of the second, are found.
        log.events = []
        let synced = ModelContext(container)
        let late = stay(synced, Self.brussels, day: 30.5, days: 0.3, .destination)
        try synced.save()
        #expect(await Self.drain(classifier, container, defaults: scratch.defaults,
                                 directory: scratch.directory, log: log))
        #expect(log.events == ["temporary"])
        #expect(try stored(late.id, container).category == .home)
        log.events = []
        try editRows(second, container) { $0.endedAt = self.date(320) }
        #expect(await Self.drain(classifier, container, defaults: scratch.defaults,
                                 directory: scratch.directory, log: log))
        #expect(log.events == ["temporary"])
    }
}
}
