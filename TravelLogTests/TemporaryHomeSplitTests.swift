//
//  TemporaryHomeSplitTests.swift
//  TravelLogTests
//
//  Always split (DESIGN-v2 Part A): a temporary home's covering splits every
//  trip that holds a stay inside its area and dates, whatever the user did with
//  it. A trip the user engaged with is archived whole in Removed Trips before
//  anything changes, its id retired, and Keep as One Trip puts it back. Only an
//  explicit keep holds a trip whole; freeing keeps today's protection. These
//  drive the real unit (`applyTemporaryHomeChangeCore`), the real save worker
//  and the real ordinary pass, as `TemporaryHomeJourneyTests` does.
//
//  Fixture time uses whole days from a fixed UTC anchor, and every
//  stay carries the GMT zone.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

/// Collects the recovery records the classifier hands its sink, one per id as
/// the queue keeps them: a later record for an id replaces the earlier one (a
/// split hands its archive again once it committed).
private final class SplitRecordBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [DissolvedTripRecord] = []
    private var calls = 0
    var failing = false
    /// The calls, counted from 1, that throw.
    var failingCalls: Set<Int> = []

    func append(_ records: [DissolvedTripRecord]) throws {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        if failing || failingCalls.contains(calls) { throw SplitInjectedError() }
        for record in records {
            if let index = stored.firstIndex(where: { $0.id == record.id }) {
                stored[index] = record
            } else {
                stored.append(record)
            }
        }
    }

    var records: [DissolvedTripRecord] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var split: [DissolvedTripRecord] { records.filter(\.isSplitRecord) }
}

private struct SplitInjectedError: Error {}

/// The ids the unit's wrapper asked to unpin.
@MainActor
private final class UnpinLog {
    var ids: [Set<UUID>] = []
}

/// What a Keep run from inside another operation returned.
@MainActor
private final class KeepLog {
    var outcome: TripClassifier.KeepSplitOutcome?
}

/// How many times a drain read the removal evidence.
@MainActor
private final class EvidenceReads {
    var count = 0
}

/// Whether a Keep waits for the pipeline latch, or already finished.
private final class KeepProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var flags = (waiting: false, finished: false)

    func markWaiting() { lock.lock(); flags.waiting = true; lock.unlock() }
    func markFinished() { lock.lock(); flags.finished = true; lock.unlock() }
    var settled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flags.waiting || flags.finished
    }
}

extension ReconciliationDrainTests {
@MainActor
@Suite("Temporary home split", IsolatedTitleDefaults())
struct TemporaryHomeSplitTests {

    private typealias Place = (lat: Double, lon: Double)
    private static let athens: Place = (38.0, 23.8)
    private static let brussels: Place = (50.8863, 4.4142)
    /// A distant northern excursion outside the Brussels area.
    private static let ieper: Place = (51.85, 4.35)
    /// About 140 km east of Brussels.
    private static let bedburg: Place = (50.85, 6.35)
    private static let vienna: Place = (48.1953, 16.3360)
    /// About 111 km north of Vienna.
    private static let brno: Place = (vienna.lat + 1, vienna.lon)
    /// 12 km north of the real home's pin: outside its measured area. No city boundary.
    private static let village: Place = (38.108, 23.8)

    private func date(_ day: Double) -> Date { TemporaryHomeFixture.date(day + 301) }

    @discardableResult
    private func stay(
        _ ctx: ModelContext, _ place: Place, _ from: Double, _ to: Double,
        _ category: StayCategory = .unclassified, fixes: Int = 2, by temporaryHomeID: UUID? = nil
    ) -> Stay {
        TemporaryHomeFixture.stay(
            ctx, place, from: date(from), to: date(to), category, hex: "S", pingCount: fixes,
            zone: "GMT", idOnlyStamp: temporaryHomeID)
    }

    @discardableResult
    private func trip(_ ctx: ModelContext, _ stays: [Stay], complete: Bool = true) -> Trip {
        TemporaryHomeFixture.trip(ctx, stays, complete: complete)
    }

    private func seedAthens(_ ctx: ModelContext) {
        TemporaryHomeFixture.realHome(ctx, "Athens", at: Self.athens).startedAt = date(-1000)
    }

    private func temporaryHome(
        _ ctx: ModelContext, at chosen: Place? = nil, from: Double = 10, until: Double? = nil
    ) -> TemporaryHome {
        TemporaryHomeFixture.temporaryHome(
            ctx, "Erasmus", at: chosen ?? Self.brussels, from: from + 301,
            until: until.map { $0 + 301 }, zone: "GMT")
    }

    private func makeClassifier(_ container: ModelContainer) async -> TripClassifier {
        await TemporaryHomeFixture.classifier(
            container, squares: [(1, Self.athens), (2, Self.brussels), (3, Self.vienna)],
            discs: [Self.village])
    }

    private func reconcile(
        _ classifier: TripClassifier, _ id: UUID, pinned: Set<UUID> = []
    ) async -> TripClassifier.TemporaryHomeReconciliationOutcome {
        await StayClassificationInference.TestHook.$availability.withValue(false) {
            await classifier.applyTemporaryHomeChangeCore(temporaryHomeID: id, pinnedTripIDs: pinned)
        }
    }

    private func ordinaryPass(_ classifier: TripClassifier) async {
        await TemporaryHomeFixture.ordinaryPass(classifier)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "TemporaryHomeSplitTests-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    private func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TemporaryHomeSplitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Reading the store

    /// Every stay's category, setting, provenance and trip, and every trip
    /// row's id, marks and name, as committed.
    private struct StoreState: Equatable {
        let stays: [UUID: String]
        let trips: [String]
        let photoAnnotations: [String]
    }

    private func storeState(_ container: ModelContainer) throws -> StoreState {
        let ctx = ModelContext(container)
        var stays: [UUID: String] = [:]
        for stay in try ctx.fetch(FetchDescriptor<Stay>()) {
            stays[stay.id] = [stay.categoryRaw, "\(stay.userOverridden)",
                              stay.temporaryHomeID?.uuidString ?? "-",
                              stay.trip?.id.uuidString ?? "-"].joined(separator: " ")
        }
        let trips = try ctx.fetch(FetchDescriptor<Trip>()).map { trip in
            [trip.id.uuidString, "\(trip.userEdited)", "\(trip.keptByTemporaryHome)",
             trip.customName ?? "-", "\(trip.isComplete)",
             (trip.stays ?? []).map(\.id.uuidString).sorted().joined(separator: ",")]
                .joined(separator: " ")
        }.sorted()
        let hidden = try ctx.fetch(FetchDescriptor<HiddenPhoto>()).map {
            ["hidden", $0.id.uuidString, $0.tripID.uuidString, $0.localIdentifier,
             $0.cloudIdentifier ?? "-", "\($0.hiddenAt.timeIntervalSince1970)"].joined(separator: " ")
        }
        let pinned = try ctx.fetch(FetchDescriptor<PinnedPhoto>()).map {
            ["pinned", $0.id.uuidString, $0.tripID.uuidString, $0.localIdentifier,
             $0.cloudIdentifier ?? "-", "\($0.pinnedAt.timeIntervalSince1970)"].joined(separator: " ")
        }
        return StoreState(stays: stays, trips: trips, photoAnnotations: (hidden + pinned).sorted())
    }

    /// The members of every trip row by id.
    private func membership(_ container: ModelContainer) throws -> [UUID: Set<UUID>] {
        var result: [UUID: Set<UUID>] = [:]
        for trip in try ModelContext(container).fetch(FetchDescriptor<Trip>()) {
            result[trip.id, default: []].formUnion((trip.stays ?? []).map(\.id))
        }
        return result
    }

    private func stayRow(_ id: UUID, _ container: ModelContainer) throws -> Stay {
        try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>(
            predicate: #Predicate { $0.id == id })).first)
    }

    private func trips(withID id: UUID, _ container: ModelContainer) throws -> [Trip] {
        try ModelContext(container).fetch(FetchDescriptor<Trip>(predicate: #Predicate { $0.id == id }))
    }

    private func engage(
        _ trip: Trip, overriding stay: Stay, _ interaction: TripClassifier.TripInteraction,
        _ ctx: ModelContext
    ) {
        switch interaction {
        case .userEdited: trip.userEdited = true
        case .customName: trip.customName = "Erasmus"
        case .pinned: break
        case .hiddenPhoto: ctx.insert(HiddenPhoto(localIdentifier: "asset-1", tripID: trip.id))
        case .pinnedPhoto: ctx.insert(PinnedPhoto(localIdentifier: "asset-2", tripID: trip.id))
        case .stayOverridden: stay.userOverridden = true
        }
    }

    // MARK: - Declaration save, an ordinary pass, then the unit

    /// The open trip is time at the base only; the completed one has a side
    /// trip to Ieper between two stretches at the base.
    nonisolated enum Shape: String, CaseIterable, Sendable {
        case openAtTheBase, completedWithASideTrip
    }

    @Test("a trip the user engaged with that a new temporary home covers, open or completed, is held by the declaration's own save, survives an ordinary pass before its unit, and is then archived and split: its id is retired, its stays at the base are home, a side trip is a trip of its own with a fresh id, and a replay and later passes change nothing",
          arguments: TripClassifier.TripInteraction.allCases, Shape.allCases)
    func heldBySaveThenSplit(
        interaction: TripClassifier.TripInteraction, shape: Shape
    ) async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        let members: [Stay]
        switch shape {
        case .openAtTheBase:
            members = [stay(ctx, Self.brussels, 10.2, 12.8, .destination),
                       stay(ctx, Self.brussels, 14.2, 15.8, .destination)]
        case .completedWithASideTrip:
            members = [stay(ctx, Self.brussels, 10.2, 12.8, .destination),
                       stay(ctx, Self.ieper, 13.2, 13.8, .destination),
                       stay(ctx, Self.brussels, 14.2, 15.8, .destination)]
            stay(ctx, Self.athens, 20.2, 25, .home)
        }
        let engaged = trip(ctx, members, complete: shape == .completedWithASideTrip)
        engage(engaged, overriding: members[1], interaction, ctx)
        try ctx.save()
        let originalID = engaged.id
        let pinned: Set<UUID> = interaction == .pinned ? [originalID] : []
        let classifier = await makeClassifier(container)

        // What the form shows: the trip is split, with its reason, not kept.
        let draft = HomeAnchor(
            id: UUID(), kind: .temporary, label: "Erasmus",
            latitude: Self.brussels.lat, longitude: Self.brussels.lon, radiusKm: 25,
            locality: nil, isoCountryCode: nil, startedAt: date(10), endedAt: nil)
        let preview = try #require(await classifier.previewTemporaryHomeChange(
            draft: draft, removing: false, pinnedTripIDs: pinned))
        #expect(preview.tripsSplit.map(\.id) == [originalID])
        #expect(preview.tripsSplit.first?.reasons == [interaction])
        #expect(preview.tripsKept.isEmpty)
        #expect(preview.tripsRebuilt.isEmpty)

        // The save holds what the preview lists, with the declaration.
        var payload = TemporaryHomeSavePayload(
            target: .add, label: "Erasmus", latitude: Self.brussels.lat,
            longitude: Self.brussels.lon, locality: "Brussels", administrativeArea: nil,
            country: "Belgium", isoCountryCode: "BE", startedAt: date(10), endedAt: nil,
            timeZoneIdentifier: "GMT", now: date(30))
        payload.keptTripIDs = preview.tripsKept.map(\.id) + preview.tripsSplit.map(\.id)
        let saved = TemporaryHomeSaveWorker.apply(
            payload, context: ModelContext(container), pendingDefaults: defaults)
        let rowID = try #require(saved.pendingReconciliation?.id)
        let held = try #require(try trips(withID: originalID, container).first)
        #expect(held.userEdited)
        #expect(held.keptByTemporaryHome == (interaction != .userEdited))

        // An ordinary pass between the save and the unit leaves it whole.
        await ordinaryPass(classifier)
        #expect(try membership(container)[originalID] == Set(members.map(\.id)))

        // A stay the user set is never converted: on the open trip it is at
        // the base, so it stays as set while the other stay there splits the trip.
        let setAtTheBase = interaction == .stayOverridden && shape == .openAtTheBase
        let box = SplitRecordBox()
        await classifier.setDissolvedRecordSink { try box.append($0) }
        #expect(await reconcile(classifier, rowID, pinned: pinned)
                == .committed(stamped: setAtTheBase ? 1 : 2, freed: 0, rebuiltTrips: 1, protectedTrips: 0))

        // Archived before anything changed, as the user left it.
        #expect(box.split.map(\.id) == [originalID])
        let record = try #require(box.split.first)
        #expect(record.splitCommitted == true)
        #expect(record.splitByTemporaryHomeID == rowID)
        #expect(record.userEdited == (interaction == .userEdited))
        #expect(record.keptByTemporaryHome != true)
        #expect(record.wasFavourite == (interaction == .pinned))
        #expect(record.customName == (interaction == .customName ? "Erasmus" : nil))
        #expect(record.isComplete == (shape == .completedWithASideTrip))
        #expect(record.stays.map(\.id) == members.map(\.id))
        #expect(record.stays.map(\.categoryRaw) == members.map { _ in "destination" })
        #expect(record.stays.map { $0.wasOverridden ?? false }
                == members.indices.map { $0 == 1 && interaction == .stayOverridden })
        let photoRows = (record.photoAnnotations ?? []).map(\.localIdentifier)
        switch interaction {
        case .hiddenPhoto: #expect(photoRows == ["asset-1"])
        case .pinnedPhoto: #expect(photoRows == ["asset-2"])
        default: #expect(photoRows.isEmpty)
        }
        let read = ModelContext(container)
        let copiedHidden = try read.fetch(FetchDescriptor<HiddenPhoto>())
        #expect(copiedHidden.count == (interaction == .hiddenPhoto && shape == .completedWithASideTrip ? 1 : 0))
        #expect(copiedHidden.allSatisfy { $0.tripID != originalID && $0.localIdentifier == "asset-1" })
        #expect(try read.fetch(FetchDescriptor<PinnedPhoto>()).isEmpty)

        // Retired: no trip carries the id; the base is home, set by the declaration.
        #expect(try trips(withID: originalID, container).isEmpty)
        for base in [members.first!, members.last!] where !(setAtTheBase && base.id == members[1].id) {
            let now = try stayRow(base.id, container)
            #expect(now.category == .home)
            #expect(now.trip == nil)
            #expect(!now.userOverridden)
            #expect(now.temporaryHomeID == rowID)
        }
        let all = try ModelContext(container).fetch(FetchDescriptor<Trip>())
        switch shape {
        case .openAtTheBase where setAtTheBase:
            // The stay the user set is a piece of its own, the user's own edit.
            let piece = try #require(all.first)
            #expect(all.count == 1)
            #expect(piece.id != originalID)
            #expect(Set((piece.stays ?? []).map(\.id)) == [members[1].id])
            #expect(piece.userEdited && !piece.keptByTemporaryHome)
            let set = try stayRow(members[1].id, container)
            #expect(set.category == .destination)
            #expect(set.userOverridden)
            #expect(set.temporaryHomeID == nil)
            #expect(record.postSplitHolders == [DissolvedTripRecord.SplitHolderRef(
                tripID: piece.id, stayIDs: [members[1].id], userEdited: true, customName: nil)])
        case .openAtTheBase:
            #expect(all.isEmpty)
            #expect(record.postSplitHolders == nil)
        case .completedWithASideTrip:
            let piece = try #require(all.first)
            #expect(all.count == 1)
            #expect(piece.id != originalID)
            #expect(Set((piece.stays ?? []).map(\.id)) == [members[1].id])
            #expect(piece.isComplete)
            #expect(piece.customName == nil)
            // A stay the user set on the side trip stays set: the piece is the user's own edit.
            #expect(piece.userEdited == (interaction == .stayOverridden))
            #expect(!piece.keptByTemporaryHome)
            #expect(try stayRow(members[1].id, container).userOverridden == (interaction == .stayOverridden))
            #expect(record.postSplitHolders == [DissolvedTripRecord.SplitHolderRef(
                tripID: piece.id, stayIDs: [members[1].id],
                userEdited: interaction == .stayOverridden, customName: nil,
                inheritedHiddenPhotoIDs: copiedHidden.isEmpty ? nil : copiedHidden.map(\.id))])
        }
        #expect(record.stays.map(\.postSplitCategoryRaw) == members.map {
            $0.id == members[1].id && (shape == .completedWithASideTrip || setAtTheBase)
                ? "destination" : "home"
        })

        // A replay and the ordinary passes after it change nothing.
        let after = try storeState(container)
        #expect(await reconcile(classifier, rowID, pinned: pinned)
                == .committed(stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 0))
        #expect(box.split.count == 1)
        #expect(try storeState(container) == after)
        for round in 1...2 {
            await ordinaryPass(classifier)
            #expect(try storeState(container) == after, "after pass \(round)")
        }
    }

    // MARK: - Covered and inherited settings

    @Test("a stay at the base the user had set as a destination, the only stay there between two weekends away, stays as the user set it when the temporary home covers it: it covers nothing, so the trip stays whole with its id and nothing is archived, through two replays")
    func coveredOverrideIsKept() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        let weekend1 = stay(ctx, Self.ieper, 10.2, 10.8, .destination)
        let dorm = stay(ctx, Self.brussels, 11.2, 13.8, .destination)
        dorm.userOverridden = true
        let weekend2 = stay(ctx, Self.bedburg, 14.2, 14.8, .destination)
        stay(ctx, Self.athens, 16.2, 20, .home)
        let original = trip(ctx, [weekend1, dorm, weekend2])
        let row = temporaryHome(ctx, until: 100)
        try ctx.save()
        let originalID = original.id

        let classifier = await makeClassifier(container)
        let box = SplitRecordBox()
        await classifier.setDissolvedRecordSink { try box.append($0) }
        #expect(await reconcile(classifier, row.id)
                == .committed(stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 0))

        let kept = try stayRow(dorm.id, container)
        #expect(kept.category == .destination)
        #expect(kept.userOverridden)
        #expect(kept.temporaryHomeID == nil)
        #expect(try membership(container) == [originalID: Set([weekend1, dorm, weekend2].map(\.id))])
        #expect(box.records.isEmpty)

        let after = try storeState(container)
        for round in 1...2 {
            #expect(await reconcile(classifier, row.id)
                    == .committed(stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 0), "replay \(round)")
            #expect(try storeState(container) == after, "replay \(round)")
        }
        #expect(box.records.isEmpty)
    }

    /// The queue's drain with its stages pointed at this classifier and store,
    /// the way `.live` points them at the app's: the real temporary-home entry
    /// point, live discovery, acknowledgements and split archives in
    /// `directory`, and removal's Keep as One Trip. `pins` stand for the
    /// favourites (none by default); `adjust` changes the stages before the drain.
    private func drain(
        _ classifier: TripClassifier, _ container: ModelContainer,
        defaults: UserDefaults, directory: URL, pins: PinnedTripsStorage? = nil,
        adjust: (inout CoverageReconciliationQueue.Stages) -> Void = { _ in }
    ) async {
        let pins = pins ?? PinnedTripsStorage(forTesting: defaults)
        var stages = CoverageReconciliationQueue.Stages(
            applyHome: { _, _ in .failed },
            applyRoutinePlace: { _, _ in .failed },
            applyTemporaryHome: { id, onSettled in
                await classifier.applyTemporaryHomeChange(
                    temporaryHomeID: id, pinnedTripIDs: { pins.pinnedIDs },
                    gate: PipelineGate(forTesting: ()),
                    unpinRetired: { ids in for id in ids { pins.unpin(id) } },
                    acknowledgementDirectory: directory, onSettled: onSettled)
            },
            generateLocalizedTitles: {},
            publish: { _, _ in },
            heal: {},
            isPersistentStore: { true },
            removalEvidence: {
                try? CoverageReconciliationQueue.removalEvidence(in: ModelContext(container))
            },
            discoveryDigests: {
                await classifier.temporaryHomeDiscoveryDigests(pinnedTripIDs: pins.pinnedIDs)
            },
            acknowledgementDirectory: directory,
            keepSplitTrips: { removedIDs in
                await HomeAreaHealing.keepSplitTrips(
                    splitBy: removedIDs, classifier: classifier, gate: PipelineGate(forTesting: ()),
                    pins: pins, queueDirectory: directory)
            })
        adjust(&stages)
        await CoverageReconciliationQueue.drainIfNeeded(defaults: defaults, stages: stages)
    }

    /// `coveredOverrideIsKept`'s store after the declaration's unit: the trip
    /// the user edited by setting the dorm, whole.
    private func seedCoveredOverride(
        _ container: ModelContainer
    ) throws -> (row: UUID, trip: UUID, weekend1: UUID, dorm: UUID, weekend2: UUID) {
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        let weekend1 = stay(ctx, Self.ieper, 10.2, 10.8, .destination)
        let dorm = stay(ctx, Self.brussels, 11.2, 13.8, .destination)
        dorm.userOverridden = true
        let weekend2 = stay(ctx, Self.bedburg, 14.2, 14.8, .destination)
        stay(ctx, Self.athens, 16.2, 20, .home)
        let original = trip(ctx, [weekend1, dorm, weekend2])
        original.userEdited = true
        let row = temporaryHome(ctx, until: 100)
        try ctx.save()
        return (row.id, original.id, weekend1.id, dorm.id, weekend2.id)
    }

    @Test("Automatic on the only stay at the base between two weekends, which the user had set as a destination, makes it home time as the temporary home's covering does: the stay is home with the declaration's stamp and no setting, the weekends are two trips, and the trip it held together is archived as any curated trip is; nothing is left owed")
    func automaticSplitsAroundACorrectedBaseStay() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let seeded = try seedCoveredOverride(container)
        let classifier = await makeClassifier(container)
        let box = SplitRecordBox()
        await classifier.setDissolvedRecordSink { try box.append($0) }
        #expect(await reconcile(classifier, seeded.row)
                == .committed(stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 0))
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let reset = await StayClassificationInference.TestHook.$availability.withValue(false) {
            await classifier.resetStayToAutomatic(
                stayID: seeded.dorm, gate: PipelineGate(forTesting: ()),
                stage: { _ = CoverageReconciliationQueue.stage(.temporaryHome, id: $0, defaults: defaults) },
                drain: { await self.drain(classifier, container, defaults: defaults, directory: directory) })
        }
        #expect(reset)
        let dorm = try stayRow(seeded.dorm, container)
        #expect(dorm.category == .home)
        #expect(!dorm.userOverridden)
        #expect(dorm.temporaryHomeID == seeded.row)
        #expect(dorm.trip == nil)
        let weekend1 = try #require(try stayRow(seeded.weekend1, container).trip?.id)
        let weekend2 = try #require(try stayRow(seeded.weekend2, container).trip?.id)
        #expect(weekend1 != weekend2)
        #expect(try trips(withID: seeded.trip, container).isEmpty)
        #expect(box.split.map(\.id) == [seeded.trip])
        #expect(CoverageReconciliationQueue.pending(defaults: defaults).isEmpty)
    }

    @Test("Automatic on a stay no temporary home holds judges it again at once on its trip, as the pipeline would, even where the model lane is on, which never classifies a stay of a trip the user edited; nothing is queued")
    func automaticJudgesAStayOutsideEveryTemporaryHome() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        let first = stay(ctx, Self.vienna, 10.2, 11.8, .destination)
        let set = stay(ctx, Self.brno, 12.2, 12.6, .transit)
        set.userOverridden = true
        let last = stay(ctx, Self.vienna, 13.2, 14.8, .destination)
        stay(ctx, Self.athens, 16.2, 20, .home)
        let edited = trip(ctx, [first, set, last])
        edited.userEdited = true
        try ctx.save()
        let tripID = edited.id
        let setID = set.id
        let classifier = await makeClassifier(container)
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let reset = await StayClassificationInference.TestHook.$availability.withValue(true) {
            await StayClassificationInference.TestHook.$response.withValue({ _ in [] }) {
                await classifier.resetStayToAutomatic(
                    stayID: setID, gate: PipelineGate(forTesting: ()),
                    stage: { _ = CoverageReconciliationQueue.stage(.temporaryHome, id: $0, defaults: defaults) },
                    drain: {})
            }
        }
        #expect(reset)
        let judged = try stayRow(setID, container)
        #expect(judged.category != .unclassified)
        #expect(!judged.userOverridden)
        #expect(judged.trip?.id == tripID)
        #expect(CoverageReconciliationQueue.pending(defaults: defaults).isEmpty)
    }

    @Test("Automatic whose save fails changes nothing and queues nothing, and says so")
    func failedAutomaticChangesNothing() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let seeded = try seedCoveredOverride(container)
        let classifier = await makeClassifier(container)
        let before = try storeState(container)
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        await classifier.failNextReconciliationSaveForTesting()
        let reset = await StayClassificationInference.TestHook.$availability.withValue(false) {
            await classifier.resetStayToAutomatic(
                stayID: seeded.dorm, gate: PipelineGate(forTesting: ()),
                stage: { _ = CoverageReconciliationQueue.stage(.temporaryHome, id: $0, defaults: defaults) },
                drain: {})
        }
        #expect(!reset)
        #expect(try storeState(container) == before)
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        #expect(CoverageReconciliationQueue.pending(defaults: defaults).isEmpty)
    }

    @Test("a trip another stay at the base covers is split around a stay there the user set, which keeps its category and setting in the piece holding it; the archive records the setting before and after alike, two replays change nothing, and Keep as One Trip puts the trip back with the setting")
    func coveredTripKeepsItsOverriddenMembers() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        let weekend1 = stay(ctx, Self.ieper, 10.2, 10.8, .destination)
        let dorm = stay(ctx, Self.brussels, 11.2, 12.8, .destination)
        dorm.userOverridden = true
        let base = stay(ctx, Self.brussels, 13.0, 13.9, .destination)
        let weekend2 = stay(ctx, Self.bedburg, 14.2, 14.8, .destination)
        stay(ctx, Self.athens, 16.2, 20, .home)
        let original = trip(ctx, [weekend1, dorm, base, weekend2])
        let row = temporaryHome(ctx, until: 100)
        try ctx.save()
        let originalID = original.id

        let classifier = await makeClassifier(container)
        let box = SplitRecordBox()
        await classifier.setDissolvedRecordSink { try box.append($0) }
        #expect(await reconcile(classifier, row.id)
                == .committed(stamped: 1, freed: 0, rebuiltTrips: 1, protectedTrips: 0))

        let set = try stayRow(dorm.id, container)
        #expect(set.category == .destination)
        #expect(set.userOverridden)
        #expect(set.temporaryHomeID == nil)
        #expect(try stayRow(base.id, container).category == .home)
        let now = try membership(container)
        #expect(now[originalID] == nil)
        #expect(Set(now.values) == [[weekend1.id, dorm.id], [weekend2.id]])
        let holder = try #require(set.trip)
        #expect(holder.userEdited && !holder.keptByTemporaryHome)

        let record = try #require(box.split.first)
        let ref = try #require(record.stays.first { $0.id == dorm.id })
        #expect(ref.categoryRaw == "destination")
        #expect(ref.wasOverridden == true)
        #expect(ref.postSplitCategoryRaw == "destination")
        #expect(ref.postSplitOverridden == true)

        let after = try storeState(container)
        for round in 1...2 {
            #expect(await reconcile(classifier, row.id)
                    == .committed(stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 0), "replay \(round)")
            #expect(try storeState(container) == after, "replay \(round)")
        }
        #expect(box.split.count == 1)

        #expect(await classifier.keepSplitTripWhole(record, pinnedTripIDs: []) == .kept)
        let back = try #require(try trips(withID: originalID, container).first)
        #expect(back.orderedStays.map(\.id) == [weekend1.id, dorm.id, base.id, weekend2.id])
        let restored = try stayRow(dorm.id, container)
        #expect(restored.category == .destination)
        #expect(restored.userOverridden)
    }

    @Test("a favourite whose dates hold a stay that becomes a qualifying home stay is split there, although none of its own stays is at the base; one whose dates hold only a single fix there is left whole and unmarked",
          arguments: [true, false])
    func favouriteHoldingACoveredStayInItsDates(qualifying: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        let away = [stay(ctx, Self.bedburg, 10.2, 10.8, .destination),
                    stay(ctx, Self.ieper, 13.2, 13.8, .destination)]
        let inside = qualifying
            ? stay(ctx, Self.brussels, 11.2, 12.8, .destination)
            : stay(ctx, Self.brussels, 11.2, 11.24, .destination, fixes: 1)
        stay(ctx, Self.athens, 15.2, 20, .home)
        let favourite = trip(ctx, away)
        let row = temporaryHome(ctx, until: 100)
        try ctx.save()
        let id = favourite.id

        let classifier = await makeClassifier(container)
        let box = SplitRecordBox()
        await classifier.setDissolvedRecordSink { try box.append($0) }
        #expect(await reconcile(classifier, row.id, pinned: [id])
                == .committed(stamped: 1, freed: 0, rebuiltTrips: qualifying ? 1 : 0, protectedTrips: 0))
        #expect(try stayRow(inside.id, container).category == .home)
        let now = try membership(container)
        if qualifying {
            #expect(box.split.map(\.id) == [id])
            #expect(now[id] == nil)
            #expect(Set(now.values) == [[away[0].id], [away[1].id]])
        } else {
            #expect(box.records.isEmpty)
            #expect(now == [id: Set(away.map(\.id))])
            let untouched = try #require(try trips(withID: id, container).first)
            #expect(!untouched.userEdited)
        }
    }

    @Test("a tripless stay at the base the user set is left as the user set it: a routine stay stays routine, and a destination stays a destination that cannot bridge the home stays around it, a trip of its own; two replays change nothing, its piece included")
    func triplessOverridesAreLeftAlone() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        let row = temporaryHome(ctx, until: 100)
        stay(ctx, Self.brussels, 10.2, 12.8, .home, by: row.id)
        let routine = stay(ctx, Self.brussels, 13.0, 13.1, .routine)
        routine.userOverridden = true
        let outing = stay(ctx, Self.brussels, 13.2, 13.8, .destination)
        outing.userOverridden = true
        stay(ctx, Self.brussels, 14.2, 15.8, .home, by: row.id)
        // A tripless stay the user did not set, so the unit has work.
        let loose = stay(ctx, Self.brussels, 16.2, 17.8, .destination)
        let side = stay(ctx, Self.ieper, 18.2, 18.8, .destination)
        try ctx.save()

        let classifier = await makeClassifier(container)
        let box = SplitRecordBox()
        await classifier.setDissolvedRecordSink { try box.append($0) }
        #expect(await reconcile(classifier, row.id)
                == .committed(stamped: 1, freed: 0, rebuiltTrips: 0, protectedTrips: 0))
        #expect(try stayRow(loose.id, container).category == .home)
        let keptRoutine = try stayRow(routine.id, container)
        #expect(keptRoutine.category == .routine)
        #expect(keptRoutine.userOverridden)
        let keptOuting = try stayRow(outing.id, container)
        #expect(keptOuting.category == .destination)
        #expect(keptOuting.userOverridden)
        // It is a trip of its own: the home stays around it bound it.
        let now = try membership(container)
        let holder = try #require(keptOuting.trip?.id)
        #expect(now[holder] == [outing.id])
        #expect(!now.values.contains { $0.contains(outing.id) && $0.contains(side.id) })

        // A piece holding a stay the user set is not covered by it: replays
        // leave the setting, the piece and the archive count as they are.
        let after = try storeState(container)
        for round in 1...2 {
            #expect(await reconcile(classifier, row.id)
                    == .committed(stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 0), "replay \(round)")
            #expect(try storeState(container) == after, "replay \(round)")
            let replayed = try stayRow(outing.id, container)
            #expect(replayed.category == .destination, "replay \(round)")
            #expect(replayed.userOverridden, "replay \(round)")
            #expect(replayed.trip?.id == holder, "replay \(round)")
        }
        #expect(box.records.isEmpty)
    }

    // MARK: - Explicit keeps, freeing and mixed edits

    @Test("a trip the user kept against the temporary home is held whole by a later covering, marked as this feature's, listed as kept and never archived")
    func explicitKeepHoldsAgainstCovering() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        let members = [stay(ctx, Self.brussels, 10.2, 12.8, .destination),
                       stay(ctx, Self.ieper, 13.2, 13.8, .destination)]
        stay(ctx, Self.athens, 15.2, 20, .home)
        let kept = trip(ctx, members)
        kept.customName = "Erasmus week"
        let row = temporaryHome(ctx, until: 100)
        row.addKeptTrip(kept.id)
        // A second copy of the declaration, as a second device leaves it: the keep counts from either.
        let twin = TemporaryHome(label: "Erasmus", latitude: Self.brussels.lat,
                                 longitude: Self.brussels.lon, startedAt: date(10),
                                 endedAt: date(100))
        twin.id = row.id
        twin.timeZoneIdentifier = "GMT"
        ctx.insert(twin)
        let loose = stay(ctx, Self.brussels, 30.2, 31.8, .destination)
        try ctx.save()
        let keptID = kept.id

        let classifier = await makeClassifier(container)
        let preview = try #require(await classifier.previewTemporaryHomeChange(
            draft: HomeAnchor(row), removing: false, pinnedTripIDs: []))
        #expect(preview.tripsKept.map(\.id) == [keptID])
        #expect(preview.tripsSplit.isEmpty)
        let box = SplitRecordBox()
        await classifier.setDissolvedRecordSink { try box.append($0) }
        #expect(await reconcile(classifier, row.id)
                == .committed(stamped: 1, freed: 0, rebuiltTrips: 0, protectedTrips: 1))
        #expect(try membership(container)[keptID] == Set(members.map(\.id)))
        #expect(try stayRow(members[0].id, container).category == .destination)
        #expect(try stayRow(loose.id, container).category == .home)
        let after = try #require(try trips(withID: keptID, container).first)
        #expect(after.userEdited)
        #expect(after.customName == "Erasmus week")
        #expect(box.records.isEmpty)
    }

    @Test("moving the pin covers one curated trip at the new place and frees the stays around a favourite at the old one: covering wins for the trip it covers, which is split, a trip both freed around and covered is split too, and only the favourite is kept")
    func mixedPinMoveCoveringWins() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        let row = temporaryHome(ctx, at: Self.vienna, until: nil)
        let rowID = row.id
        let wrong = [stay(ctx, Self.vienna, 10.2, 12.8, .home, by: rowID),
                     stay(ctx, Self.vienna, 15.2, 19.8, .home, by: rowID)]
        let favourite = stay(ctx, Self.brno, 13.2, 14.8, .destination)
        let named = [stay(ctx, Self.brussels, 20.2, 22.8, .destination),
                     stay(ctx, Self.ieper, 23.2, 23.8, .destination),
                     stay(ctx, Self.brussels, 24.2, 29.8, .destination)]
        let freedNext = stay(ctx, Self.vienna, 30.2, 32.8, .home, by: rowID)
        // Right after a stay that stops being home, and holding one at the new place.
        let both = [stay(ctx, Self.brussels, 33.2, 34.8, .destination),
                    stay(ctx, Self.bedburg, 35.2, 35.8, .destination)]
        stay(ctx, Self.athens, 37.2, 40.8, .home)
        let favouriteID = trip(ctx, [favourite]).id
        let namedTrip = trip(ctx, named)
        namedTrip.customName = "Beringen weekend"
        let bothTrip = trip(ctx, both)
        ctx.insert(HiddenPhoto(localIdentifier: "asset-9", tripID: bothTrip.id))
        try ctx.save()
        let (namedID, bothID) = (namedTrip.id, bothTrip.id)

        // The form previews the moved pin, then saves it with what it holds.
        let classifier = await makeClassifier(container)
        let draft = HomeAnchor(
            id: rowID, kind: .temporary, label: "Erasmus",
            latitude: Self.brussels.lat, longitude: Self.brussels.lon, radiusKm: 25,
            locality: "Brussels", isoCountryCode: "BE", startedAt: date(10), endedAt: nil)
        let preview = try #require(await classifier.previewTemporaryHomeChange(
            draft: draft, removing: false, pinnedTripIDs: [favouriteID]))
        #expect(preview.tripsKept.map(\.id) == [favouriteID])
        #expect(preview.tripsSplit.map(\.id) == [namedID, bothID])
        #expect(preview.tripsSplit.map(\.reasons) == [[.customName], [.hiddenPhoto]])
        var payload = TemporaryHomeSavePayload(
            target: .edit(rowID), label: "Erasmus",
            latitude: Self.brussels.lat, longitude: Self.brussels.lon,
            locality: "Brussels", administrativeArea: nil, country: "Belgium",
            isoCountryCode: "BE", startedAt: date(10), endedAt: nil,
            timeZoneIdentifier: "GMT", now: date(41))
        payload.keptTripIDs = preview.tripsKept.map(\.id) + preview.tripsSplit.map(\.id)
        let moved = TemporaryHomeSaveWorker.apply(
            payload, context: ModelContext(container), pendingDefaults: defaults)
        #expect(moved.pendingReconciliation?.id == rowID)
        // Held by the save, all three ride out an ordinary pass before the unit.
        await ordinaryPass(classifier)
        for id in [favouriteID, namedID, bothID] {
            #expect(try trips(withID: id, container).first?.keptByTemporaryHome == true)
        }
        let box = SplitRecordBox()
        await classifier.setDissolvedRecordSink { try box.append($0) }
        let outcome = await reconcile(classifier, rowID, pinned: [favouriteID])
        #expect(outcome == .committed(
            stamped: preview.staysJoining, freed: 3,
            rebuiltTrips: preview.tripsRebuilt.count + preview.tripsSplit.count,
            protectedTrips: 1))
        #expect(Set(box.split.map(\.id)) == [namedID, bothID])
        // The holds were the feature's, not the user's.
        #expect(box.split.allSatisfy { !$0.userEdited })
        #expect(try trips(withID: namedID, container).isEmpty)
        #expect(try trips(withID: bothID, container).isEmpty)
        let kept = try #require(try trips(withID: favouriteID, container).first)
        #expect(Set((kept.stays ?? []).map(\.id)) == [favourite.id])
        #expect(kept.userEdited && kept.keptByTemporaryHome)
        for stay in wrong + [freedNext] { #expect(try stayRow(stay.id, container).category == .unclassified) }
        let hiddenAfter = try ModelContext(container).fetch(FetchDescriptor<HiddenPhoto>())
        let bothArchive = try #require(box.split.first { $0.id == bothID })
        #expect(Set(hiddenAfter.map(\.tripID)) == Set((bothArchive.postSplitHolders ?? []).map(\.tripID)))
        #expect(hiddenAfter.allSatisfy { $0.localIdentifier == "asset-9" })
    }

    @Test("a removal that frees the stays around a favourite holds it in its own save, the ordinary pass before the unit leaves it whole, and the unit keeps it as before: marked, with its stays and id, and nothing archived")
    func freeingHoldKeepsAsBefore() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        let row = temporaryHome(ctx, until: nil)
        let rowID = row.id
        stay(ctx, Self.brussels, 10.2, 12.8, .home, by: rowID)
        let favourite = [stay(ctx, Self.ieper, 13.2, 13.8, .destination),
                         stay(ctx, Self.bedburg, 14.2, 14.8, .destination)]
        stay(ctx, Self.brussels, 15.2, 19.8, .home, by: rowID)
        stay(ctx, Self.athens, 21.2, 30.8, .home)
        let favouriteID = trip(ctx, favourite).id
        try ctx.save()

        let classifier = await makeClassifier(container)
        let preview = try #require(await classifier.previewTemporaryHomeChange(
            draft: HomeAnchor(row), removing: true, pinnedTripIDs: [favouriteID]))
        #expect(preview.tripsKept.map(\.id) == [favouriteID])
        #expect(preview.tripsSplit.isEmpty)
        let removed = TemporaryHomeSaveWorker.apply(
            .removing(rowID, now: date(40),
                      keptTripIDs: preview.tripsKept.map(\.id) + preview.tripsSplit.map(\.id)),
            context: ModelContext(container), pendingDefaults: defaults)
        #expect(removed.pendingReconciliation?.id == rowID)
        await ordinaryPass(classifier)
        #expect(try membership(container)[favouriteID] == Set(favourite.map(\.id)))

        let box = SplitRecordBox()
        await classifier.setDissolvedRecordSink { try box.append($0) }
        #expect(await reconcile(classifier, rowID, pinned: [favouriteID])
                == .committed(stamped: 0, freed: 2, rebuiltTrips: 0, protectedTrips: 1))
        #expect(box.records.isEmpty)
        #expect(try membership(container)[favouriteID] == Set(favourite.map(\.id)))
        let kept = try #require(try trips(withID: favouriteID, container).first)
        #expect(kept.userEdited && kept.keptByTemporaryHome)
    }

    // MARK: - Archive durability

    @Test("an archive the sink cannot write fails the unit: nothing changes, the trip keeps its id, stays and categories, and a retry splits it")
    func sinkFailureChangesNothing() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let (row, original) = try seedSemesterTrip(container)
        let classifier = await makeClassifier(container)
        let box = SplitRecordBox()
        box.failing = true
        await classifier.setDissolvedRecordSink { try box.append($0) }
        let before = try storeState(container)
        #expect(await reconcile(classifier, row, pinned: [original]) == .failed)
        #expect(try storeState(container) == before)
        box.failing = false
        #expect(await reconcile(classifier, row, pinned: [original]).isSettled)
        #expect(box.split.map(\.id) == [original])
        #expect(try trips(withID: original, container).isEmpty)
    }

    @Test("a deleting save that fails after the archive was written leaves the trip as it was and the archive prepared; the user renames the trip and sets a stay before the retry, which commits and archives the trip as it then was, and Keep as One Trip, handed the archive as read before the retry, uses the queued one and puts back the name and the setting")
    func saveFailureKeepsThePreparedArchive() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let (row, original) = try seedSemesterTrip(container)
        let classifier = await makeClassifier(container)
        await classifier.setDissolvedRecordSink {
            try DissolvedTripQueue.append($0, in: directory)
        }
        let before = try storeState(container)
        await classifier.failNextReconciliationSaveForTesting()
        #expect(await reconcile(classifier, row, pinned: [original]) == .failed)
        #expect(try storeState(container) == before)
        let prepared = try #require(DissolvedTripQueue.load(from: directory).first)
        #expect(prepared.id == original && prepared.isSplitRecord)
        #expect(prepared.splitCommitted != true)

        // The trip is still there: the user renames it and sets its first stay.
        let ctx = ModelContext(container)
        let trip = try #require(try ctx.fetch(FetchDescriptor<Trip>(
            predicate: #Predicate { $0.id == original })).first)
        trip.customName = "Erasmus semester"
        trip.userEdited = true
        let firstID = prepared.stays[0].id
        let first = try #require(try ctx.fetch(FetchDescriptor<Stay>(
            predicate: #Predicate { $0.id == firstID })).first)
        first.category = .transit
        first.userOverridden = true
        try ctx.save()

        #expect(await reconcile(classifier, row, pinned: [original]).isSettled)
        let queued = DissolvedTripQueue.load(from: directory)
        #expect(queued.count == 1)
        let record = try #require(queued.first)
        // The archive is the trip as the committed split found it.
        #expect(record.splitCommitted == true)
        #expect(record.customName == "Erasmus semester")
        #expect(record.userEdited)
        #expect(record.stays.map(\.categoryRaw) == ["transit", "destination", "destination"])
        #expect(record.stays.map(\.wasOverridden) == [true, true, false])
        #expect(record.photoAnnotations?.map(\.localIdentifier) == ["asset-1"])
        // The pieces are the ones the committed retry made.
        let pieces = Set(try membership(container).keys)
        #expect(Set((record.postSplitHolders ?? []).map(\.tripID)) == pieces)
        #expect(!pieces.isEmpty)

        let kept = await StayClassificationInference.TestHook.$availability.withValue(false) {
            await HomeAreaHealing.keepSplitTrip(
                prepared, classifier: classifier, gate: PipelineGate(forTesting: ()),
                pins: PinnedTripsStorage(forTesting: defaults), queueDirectory: directory)
        }
        #expect(kept == .kept)
        let back = try #require(try trips(withID: original, container).first)
        #expect(back.customName == "Erasmus semester")
        #expect(back.orderedStays.map(\.id) == prepared.stays.map(\.id))
        let restored = try stayRow(firstID, container)
        #expect(restored.category == .transit)
        #expect(restored.userOverridden)
        #expect(DissolvedTripQueue.load(from: directory).isEmpty)
    }

    @Test("a split whose commit cannot be marked in the queue still commits, and its archive stays prepared")
    func failedCommitMarkLeavesThePreparedArchive() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let (row, original) = try seedSemesterTrip(container)
        let classifier = await makeClassifier(container)
        let box = SplitRecordBox()
        box.failingCalls = [2]
        await classifier.setDissolvedRecordSink { try box.append($0) }
        #expect(await reconcile(classifier, row, pinned: [original]).isSettled)
        #expect(try trips(withID: original, container).isEmpty)
        let record = try #require(box.split.first)
        #expect(record.splitCommitted != true)
    }

    @Test("a prepared archive is replaced whole by a later split of the trip, keeping both photo rows; a split's commit marks only the archive it prepared, never one forgotten since; an archive whose Keep committed is replaced whole by a later split, without its photo rows")
    func preparedArchiveIsReplacedWhole() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let prepared = splitRecord(id: id, holders: [UUID()], photos: ["a"], committed: false)
        try DissolvedTripQueue.append([prepared], in: directory)
        var retried = splitRecord(id: id, name: "Renamed", holders: [UUID()], photos: ["b"], committed: false)
        retried.stays = [DissolvedTripRecord.StayRef(
            id: prepared.stays[0].id, categoryRaw: "transit", orderInTrip: 0,
            wasOverridden: true, postSplitCategoryRaw: "transit", postSplitOverridden: true)]
        try DissolvedTripQueue.append([retried], in: directory)
        var queued = try #require(DissolvedTripQueue.load(from: directory).first)
        #expect(DissolvedTripQueue.load(from: directory).count == 1)
        #expect(queued.customName == "Renamed")
        #expect(queued.stays == retried.stays)
        #expect(queued.postSplitHolders == retried.postSplitHolders)
        #expect(queued.photoAnnotations?.map(\.localIdentifier) == ["b", "a"])

        // Its commit marks it, as it is.
        var committed = retried
        committed.splitCommitted = true
        try DissolvedTripQueue.append([committed], in: directory)
        queued = try #require(DissolvedTripQueue.load(from: directory).first)
        #expect(queued.splitCommitted == true)
        #expect(queued.customName == "Renamed")
        #expect(queued.photoAnnotations?.map(\.localIdentifier) == ["b", "a"])

        // Forgotten before the mark landed: the mark brings nothing back.
        try DissolvedTripQueue.remove(ids: [id], in: directory)
        try DissolvedTripQueue.append([committed], in: directory)
        #expect(DissolvedTripQueue.load(from: directory).isEmpty)

        // A Keep that committed spent the archive.
        try DissolvedTripQueue.append([retried], in: directory)
        try DissolvedTripQueue.append([committed], in: directory)
        try DissolvedTripQueue.markKeepCommitted(id: id, in: directory)
        #expect(try DissolvedTripQueue.record(id: id, in: directory)?.keepCommitted == true)
        let later = splitRecord(id: id, name: "Again", holders: [UUID()], photos: ["c"], committed: false)
        try DissolvedTripQueue.append([later], in: directory)
        queued = try #require(DissolvedTripQueue.load(from: directory).first)
        #expect(queued.customName == "Again")
        #expect(queued.keepCommitted != true)
        #expect(queued.splitCommitted != true)
        #expect(queued.photoAnnotations?.map(\.localIdentifier) == ["c"])
    }

    @Test("two trip rows sharing an id that the covering splits leave one archive holding both rows' stays and the name one of them carried, and no trip with that id")
    func uuidTwinsShareOneArchive() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        let first = [stay(ctx, Self.brussels, 10.2, 12.8, .destination),
                     stay(ctx, Self.ieper, 13.2, 13.8, .destination)]
        let second = [stay(ctx, Self.bedburg, 14.2, 14.8, .destination)]
        stay(ctx, Self.athens, 16.2, 20, .home)
        let named = trip(ctx, first)
        let twin = trip(ctx, second)
        twin.id = named.id
        twin.customName = "Erasmus"
        let row = temporaryHome(ctx, until: 100)
        try ctx.save()
        let id = named.id

        let classifier = await makeClassifier(container)
        let box = SplitRecordBox()
        await classifier.setDissolvedRecordSink { try box.append($0) }
        #expect(await reconcile(classifier, row.id).isSettled)
        #expect(box.split.count == 1)
        let record = try #require(box.split.first)
        #expect(record.id == id)
        #expect(Set(record.stays.map(\.id)) == Set((first + second).map(\.id)))
        #expect(record.customName == "Erasmus")
        #expect(try trips(withID: id, container).isEmpty)
    }

    @Test("two trip rows sharing an id with different names and different stays leave one archive that keeps every name: the row holding the most stays gives the trip's name and the other is kept beside it, through the queue's file and its title scrubbing; Keep as One Trip puts the trip back under the first")
    func uuidTwinNamesAreAllKept() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        let first = [stay(ctx, Self.brussels, 10.2, 12.8, .destination),
                     stay(ctx, Self.ieper, 13.2, 13.8, .destination)]
        let second = [stay(ctx, Self.bedburg, 14.2, 14.8, .destination)]
        stay(ctx, Self.athens, 16.2, 20, .home)
        let named = trip(ctx, first)
        named.customName = "Erasmus"
        let twin = trip(ctx, second)
        twin.id = named.id
        twin.customName = "Bedburg weekend"
        let row = temporaryHome(ctx, until: 100)
        try ctx.save()
        let id = named.id

        let classifier = await makeClassifier(container)
        let box = SplitRecordBox()
        await classifier.setDissolvedRecordSink { try box.append($0) }
        #expect(await reconcile(classifier, row.id).isSettled)
        #expect(box.split.count == 1)
        let record = try #require(box.split.first)
        #expect(Set(record.stays.map(\.id)) == Set((first + second).map(\.id)))
        #expect(record.customName == "Erasmus")
        #expect(record.otherCustomNames == ["Bedburg weekend"])
        let decoded = try JSONDecoder().decode(
            DissolvedTripRecord.self, from: try JSONEncoder().encode(record))
        #expect(decoded.otherCustomNames == ["Bedburg weekend"])
        #expect(record.removingGeneratedTitleArtifacts().otherCustomNames == ["Bedburg weekend"])

        #expect(await classifier.keepSplitTripWhole(record, pinnedTripIDs: []) == .kept)
        let back = try trips(withID: id, container)
        #expect(back.count == 1)
        #expect(back.first?.customName == "Erasmus")
        #expect(Set((back.first?.stays ?? []).map(\.id)) == Set((first + second).map(\.id)))
    }

    /// A named trip to the base with a side trip to Ieper whose stay is two
    /// physical rows of one stay, as sync can leave it; `copySet` makes the
    /// second row one the user set.
    private func seedStayTwins(
        _ container: ModelContainer, copySet: Bool
    ) throws -> (row: UUID, trip: UUID, stays: [UUID]) {
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        let first = stay(ctx, Self.brussels, 10.2, 12.8, .destination)
        let side = stay(ctx, Self.ieper, 13.2, 13.8, .destination)
        let copy = stay(ctx, Self.ieper, 13.2, 13.8, .destination)
        copy.id = side.id
        copy.userOverridden = copySet
        let last = stay(ctx, Self.brussels, 14.2, 15.8, .destination)
        stay(ctx, Self.athens, 20.2, 25, .home)
        let named = trip(ctx, [first, side, copy, last])
        named.customName = "Erasmus"
        let row = temporaryHome(ctx, until: 100)
        try ctx.save()
        return (row.id, named.id, [first.id, side.id, last.id])
    }

    @Test("two physical rows of one stay on a trip the covering splits are one stay in its archive; once the store keeps one row, Keep as One Trip puts the trip back")
    func stayTwinsAreOneArchivedStay() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let (row, id, stays) = try seedStayTwins(container, copySet: false)
        let classifier = await makeClassifier(container)
        let box = SplitRecordBox()
        await classifier.setDissolvedRecordSink { try box.append($0) }
        #expect(await reconcile(classifier, row).isSettled)
        let record = try #require(box.split.first)
        #expect(record.stays.map(\.id) == stays)

        // The store converges on one row of the stay.
        let ctx = ModelContext(container)
        let twinID = stays[1]
        let rows = try ctx.fetch(FetchDescriptor<Stay>(predicate: #Predicate { $0.id == twinID }))
        #expect(rows.count == 2)
        ctx.delete(try #require(rows.last))
        try ctx.save()
        #expect(await classifier.keepSplitTripWhole(record, pinnedTripIDs: []) == .kept)
        #expect(try membership(container)[id] == Set(stays))
    }

    @Test("two physical rows of one stay set differently cannot be one stay in an archive: the unit fails before anything changes and archives nothing")
    func conflictingStayTwinsFailTheUnit() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let (row, id, _) = try seedStayTwins(container, copySet: true)
        let classifier = await makeClassifier(container)
        let box = SplitRecordBox()
        await classifier.setDissolvedRecordSink { try box.append($0) }
        let before = try storeState(container)
        #expect(await reconcile(classifier, row) == .failed)
        #expect(try storeState(container) == before)
        #expect(box.records.isEmpty)
        #expect(try trips(withID: id, container).count == 1)
    }

    @Test("an archive that Keep as One Trip or Forget removed stays removed when the classifier's parked records are drained and appended, as healing's belt does",
          arguments: [false, true])
    func drainNeverBringsBackARemovedArchive(forget: Bool) async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let (row, original) = try seedSemesterTrip(container)
        let classifier = await makeClassifier(container)
        await classifier.setDissolvedRecordSink {
            try DissolvedTripQueue.append($0, in: directory)
        }
        #expect(await reconcile(classifier, row, pinned: [original]).isSettled)
        let record = try #require(DissolvedTripQueue.load(from: directory).first)
        if forget {
            try DissolvedTripQueue.remove(ids: [record.id], in: directory)
        } else {
            let kept = await StayClassificationInference.TestHook.$availability.withValue(false) {
                await HomeAreaHealing.keepSplitTrip(
                    record, classifier: classifier, gate: PipelineGate(forTesting: ()),
                    pins: PinnedTripsStorage(forTesting: defaults), queueDirectory: directory)
            }
            #expect(kept == .kept)
        }
        #expect(DissolvedTripQueue.load(from: directory).isEmpty)

        let parked = await classifier.drainParkedDissolvedTrips()
        try DissolvedTripQueue.append(parked, in: directory)
        #expect(DissolvedTripQueue.load(from: directory).isEmpty)
    }

    /// Puts an archive in the queue as its split does: written prepared before
    /// the deleting save, then marked committed after it.
    private func enqueue(_ record: DissolvedTripRecord, in directory: URL) throws {
        var prepared = record
        prepared.splitCommitted = nil
        try DissolvedTripQueue.append([prepared], in: directory)
        if record.splitCommitted == true { try DissolvedTripQueue.append([record], in: directory) }
    }

    private func splitRecord(
        id: UUID = UUID(), name: String? = "Erasmus", holders: [UUID] = [],
        photos: [String] = [], committed: Bool = true
    ) -> DissolvedTripRecord {
        var record = DissolvedTripRecord(
            id: id, dissolvedAt: date(40), displayName: name ?? "Brussels",
            startDate: date(10), endDate: date(16), isComplete: true,
            destinationSummary: "Brussels, Ieper", countryCodes: "BE",
            classifiedByAI: false, aiGeneratedTitle: "Semester in Brussels",
            aiGeneratedSummary: nil, summarySourceRaw: nil, sourceRaw: "liveSLC",
            customName: name, userEdited: false,
            stays: [DissolvedTripRecord.StayRef(
                id: UUID(), categoryRaw: "destination", orderInTrip: 0,
                temporaryHomeID: nil, temporaryHomeRevision: nil, wasOverridden: true,
                postSplitCategoryRaw: "home", postSplitOverridden: false)])
        record.splitByTemporaryHomeID = UUID()
        record.wasFavourite = true
        record.splitCommitted = committed ? true : nil
        record.postSplitHolders = holders.map {
            DissolvedTripRecord.SplitHolderRef(tripID: $0, stayIDs: [], userEdited: false, customName: nil)
        }
        record.photoAnnotations = photos.map {
            DissolvedTripRecord.PhotoAnnotationRef(
                id: UUID(), isPinned: false, localIdentifier: $0, cloudIdentifier: nil, date: date(12))
        }
        return record
    }

    @Test("a committed split archive is never replaced: a later record for the same trip only adds the photo rows it lacks, and a later split brings only the pieces it made; scrubbing generated titles keeps every split field")
    func splitArchiveIsImmutable() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let firstPieces = [UUID()]
        let archive = splitRecord(id: id, holders: firstPieces, photos: ["a"])
        try enqueue(archive, in: directory)

        var poorer = splitRecord(id: id, name: nil, photos: ["a", "b"])
        poorer.splitByTemporaryHomeID = nil
        poorer.wasFavourite = nil
        try DissolvedTripQueue.append([poorer], in: directory)
        var queued = try #require(DissolvedTripQueue.load(from: directory).first)
        #expect(queued.customName == "Erasmus")
        #expect(queued.splitByTemporaryHomeID == archive.splitByTemporaryHomeID)
        #expect(queued.wasFavourite == true)
        #expect(queued.stays == archive.stays)
        #expect(queued.postSplitHolders == archive.postSplitHolders)
        #expect(queued.photoAnnotations?.map(\.localIdentifier) == ["a", "b"])

        let laterPieces = [UUID()]
        var resplit = splitRecord(id: id, name: "Other", holders: laterPieces)
        resplit.stays = [DissolvedTripRecord.StayRef(
            id: archive.stays[0].id, categoryRaw: "home", orderInTrip: 0,
            postSplitCategoryRaw: "transit", postSplitOverridden: true)]
        try DissolvedTripQueue.append([resplit], in: directory)
        queued = try #require(DissolvedTripQueue.load(from: directory).first)
        #expect(DissolvedTripQueue.load(from: directory).count == 1)
        #expect(queued.customName == "Erasmus")
        #expect(queued.stays.map(\.categoryRaw) == ["destination"])
        #expect(queued.stays.map(\.wasOverridden) == [true])
        #expect(queued.stays.map(\.postSplitCategoryRaw) == ["transit"])
        #expect(queued.postSplitHolders?.map(\.tripID) == laterPieces + firstPieces)

        let scrubbed = queued.removingGeneratedTitleArtifacts()
        #expect(scrubbed.aiGeneratedTitle == nil)
        #expect(scrubbed.splitByTemporaryHomeID == queued.splitByTemporaryHomeID)
        #expect(scrubbed.wasFavourite == queued.wasFavourite)
        #expect(scrubbed.postSplitHolders == queued.postSplitHolders)
        #expect(scrubbed.splitCommitted == true)
        #expect(scrubbed.stays == queued.stays)
        try DissolvedTripQueue.scrubGeneratedTitles(in: directory)
        #expect(DissolvedTripQueue.load(from: directory).first?.splitByTemporaryHomeID
                == queued.splitByTemporaryHomeID)

        // A split archive whose stay a discarded import deleted stays too: Keep or Forget only.
        try DissolvedTripQueue.removeRecords(
            deletedStayIDs: [archive.stays[0].id], remainingStayIDs: [],
            remainingTripIDs: [], in: directory)
        #expect(DissolvedTripQueue.load(from: directory).map(\.id) == [id])

        // A record written before V21 decodes the split fields as absent.
        var legacy = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(archive)) as? [String: Any])
        for key in ["splitByTemporaryHomeID", "wasFavourite", "postSplitHolders", "splitCommitted"] {
            legacy[key] = nil
        }
        let decoded = try JSONDecoder().decode(
            DissolvedTripRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(!decoded.isSplitRecord)
        #expect(decoded.wasFavourite == nil)
        #expect(decoded.splitCommitted == nil && decoded.keepCommitted == nil)
    }

    @Test("no restore path brings a split archive back and no pruning path drops it: a restore reports its stays claimed, the rescue skips it even when favourited, a returned trip with its id is not taken as the trip back, and settlement prunes nothing")
    func splitArchiveSkipsRestoreAndPruning() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let (row, original) = try seedSemesterTrip(container)
        let classifier = await makeClassifier(container)
        let box = SplitRecordBox()
        await classifier.setDissolvedRecordSink { try box.append($0) }
        #expect(await reconcile(classifier, row, pinned: [original]).isSettled)
        let record = try #require(box.split.first)
        let before = try storeState(container)

        #expect(await classifier.restoreDissolvedTrip(record, markStaysSacred: true) == .staysClaimed)
        #expect(await classifier.restoreDissolvedTrip(record, markStaysSacred: false) == .staysClaimed)
        let rescue = await classifier.rescueDissolvedTrips([record], pinnedTripIDs: [original])
        #expect(rescue.restored.isEmpty && rescue.prunable.isEmpty)
        #expect(await classifier.settleReturnedDissolvedTrips([record]).isEmpty)
        #expect(try storeState(container) == before)

        // Even a row with its id holding exactly its stays is not "back whole" for it.
        let ctx = ModelContext(container)
        let ids = record.stays.map(\.id)
        let stays = try ctx.fetch(FetchDescriptor<Stay>(predicate: #Predicate { ids.contains($0.id) }))
        let returned = Trip(startDate: date(10))
        returned.id = original
        ctx.insert(returned)
        for stay in stays { stay.trip = returned }
        #expect(!TripClassifier.returnedTripIsWhole(record, rows: [returned], stays: stays))
    }

    // MARK: - Keep as One Trip

    /// A favourited completed semester trip with a hidden photo and a side
    /// trip the user set as a destination, split by a new temporary home.
    private struct Split {
        let container: ModelContainer
        let classifier: TripClassifier
        let rowID: UUID
        let tripID: UUID
        let base: [UUID]
        let ieper: UUID
        let record: DissolvedTripRecord
    }

    private func seedSemesterTrip(
        _ container: ModelContainer, favourite: Bool = true, overriddenSide: Bool = true
    ) throws -> (row: UUID, trip: UUID) {
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        let members = [stay(ctx, Self.brussels, 10.2, 12.8, .destination),
                       stay(ctx, Self.ieper, 13.2, 13.8, .destination),
                       stay(ctx, Self.brussels, 14.2, 15.8, .destination)]
        members[1].userOverridden = overriddenSide
        stay(ctx, Self.athens, 20.2, 25, .home)
        let semester = trip(ctx, members)
        semester.aiGeneratedTitle = "Semester in Brussels"
        ctx.insert(HiddenPhoto(localIdentifier: "asset-1", tripID: semester.id))
        let row = temporaryHome(ctx)
        // A second copy of the declaration: a keep is written on every row.
        let twin = TemporaryHome(label: "Erasmus", latitude: Self.brussels.lat,
                                 longitude: Self.brussels.lon, startedAt: date(10))
        twin.id = row.id
        ctx.insert(twin)
        try ctx.save()
        return (row.id, semester.id)
    }

    /// `overriddenSide` false: the piece holding the side trip is not edited.
    private func makeSplit(overriddenSide: Bool = true) async throws -> Split {
        let container = try TestSupport.makeInMemoryContainer()
        let (rowID, tripID) = try seedSemesterTrip(container, overriddenSide: overriddenSide)
        let classifier = await makeClassifier(container)
        let box = SplitRecordBox()
        await classifier.setDissolvedRecordSink { try box.append($0) }
        #expect(await reconcile(classifier, rowID, pinned: [tripID]).isSettled)
        let record = try #require(box.split.first)
        return Split(
            container: container, classifier: classifier, rowID: rowID, tripID: tripID,
            base: [record.stays[0].id, record.stays[2].id], ieper: record.stays[1].id,
            record: record)
    }

    private func pieceHolding(_ stayID: UUID, _ container: ModelContainer) throws -> Trip {
        try #require(try stayRow(stayID, container).trip)
    }

    @Test("Keep as One Trip with nothing done since the split puts the trip back whole under its id, with its categories, settings, photo row, edit mark and no provenance on its stays, removes the piece, and adds it to the kept trips of every copy of the temporary home, which then holds it against a replay; a second Keep finds it whole and changes nothing")
    func keepPutsTheTripBack() async throws {
        let split = try await makeSplit()
        let container = split.container
        // The piece holding the side trip is edited from birth: it holds a stay the user set.
        let piece = try pieceHolding(split.ieper, container)
        #expect(piece.userEdited)
        let pieceID = piece.id

        #expect(await split.classifier.keepSplitTripWhole(split.record, pinnedTripIDs: []) == .kept)
        let back = try #require(try trips(withID: split.tripID, container).first)
        #expect(try trips(withID: split.tripID, container).count == 1)
        #expect(back.orderedStays.map(\.id) == split.record.stays.map(\.id))
        #expect(back.isComplete)
        #expect(back.startDate == date(10.2))
        #expect(back.endDate == date(15.8))
        #expect(back.userEdited)
        #expect(back.keptByTemporaryHome)
        for stay in back.orderedStays {
            #expect(stay.category == .destination)
            #expect(stay.temporaryHomeID == nil)
            #expect(stay.temporaryHomeRevision == nil)
            #expect(stay.userOverridden == (stay.id == split.ieper))
        }
        #expect(try trips(withID: pieceID, container).isEmpty)
        let read = ModelContext(container)
        #expect(try read.fetch(FetchDescriptor<HiddenPhoto>()).map(\.tripID) == [split.tripID])
        let rows = try read.fetch(FetchDescriptor<TemporaryHome>())
        #expect(rows.count == 2)
        for row in rows { #expect(row.keptTripIDSet == [split.tripID]) }

        let kept = try storeState(container)
        #expect(await split.classifier.keepSplitTripWhole(split.record, pinnedTripIDs: []) == .kept)
        #expect(try storeState(container) == kept)
        // The covering that split it now holds it whole.
        #expect(await reconcile(split.classifier, split.rowID)
                == .committed(stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 1))
        await ordinaryPass(split.classifier)
        #expect(try membership(container)[split.tripID] == Set(split.record.stays.map(\.id)))
    }

    @Test("Keep as One Trip after a recorded stay's place changed puts back the trip's stored narrative, which nothing can regenerate, while its title stays dropped")
    func keepRestoresTheNarrativeAfterAPlaceChange() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let (rowID, tripID) = try seedSemesterTrip(container)
        let seeded = ModelContext(container)
        let original = try #require(try seeded.fetch(FetchDescriptor<Trip>(
            predicate: #Predicate { $0.id == tripID })).first)
        original.aiGeneratedSummary = "A semester of waffles and trains."
        original.summarySourceRaw = SummarySource.foundationModels.rawValue
        try seeded.save()
        let classifier = await makeClassifier(container)
        let box = SplitRecordBox()
        await classifier.setDissolvedRecordSink { try box.append($0) }
        #expect(await reconcile(classifier, rowID, pinned: [tripID]).isSettled)
        let record = try #require(box.split.first)
        #expect(record.aiGeneratedSummary == "A semester of waffles and trains.")

        let ctx = ModelContext(container)
        let baseID = record.stays[0].id
        let moved = try #require(try ctx.fetch(FetchDescriptor<Stay>(
            predicate: #Predicate { $0.id == baseID })).first)
        moved.locality = "Renamed Quarter"
        try ctx.save()

        #expect(await classifier.keepSplitTripWhole(record, pinnedTripIDs: []) == .kept)
        let back = try #require(try trips(withID: tripID, container).first)
        #expect(record.derivedSemanticDigest
                != TripTitleStore.semanticDigest(for: TripTitleStore.semanticSnapshot(for: back)))
        #expect(back.aiGeneratedTitle == nil)
        #expect(back.aiGeneratedSummary == "A semester of waffles and trains.")
        #expect(back.summarySourceRaw == SummarySource.foundationModels.rawValue)
        #expect(back.summaryGeneratedAt == record.endDate)
    }

    @Test("a split preserves hidden local and cloud photo identities on every new piece, leaves pins archived, and an untouched Keep restores only the original annotation rows")
    func hiddenChoicesFollowEveryPiece() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        let members = [stay(ctx, Self.brussels, 10.2, 10.8, .destination),
                       stay(ctx, Self.ieper, 11.2, 11.8, .destination),
                       stay(ctx, Self.brussels, 12.2, 12.8, .destination),
                       stay(ctx, Self.bedburg, 13.2, 13.8, .destination),
                       stay(ctx, Self.brussels, 14.2, 14.8, .destination)]
        stay(ctx, Self.athens, 20.2, 25, .home)
        let original = trip(ctx, members)
        let hidden = HiddenPhoto(localIdentifier: "local-hidden", tripID: original.id)
        hidden.cloudIdentifier = "cloud-hidden"
        hidden.hiddenAt = date(5)
        ctx.insert(hidden)
        let pinned = PinnedPhoto(localIdentifier: "local-pinned", tripID: original.id)
        ctx.insert(pinned)
        let row = temporaryHome(ctx)
        try ctx.save()
        let classifier = await makeClassifier(container)
        let box = SplitRecordBox()
        await classifier.setDissolvedRecordSink { try box.append($0) }
        #expect(await reconcile(classifier, row.id).isSettled)
        let record = try #require(box.split.first)
        let pieces = try membership(container)
        #expect(pieces.count == 2)
        let copied = try ModelContext(container).fetch(FetchDescriptor<HiddenPhoto>())
        #expect(Set(copied.map(\.tripID)) == Set(pieces.keys))
        #expect(copied.count == pieces.count)
        #expect(Set(copied.map(\.id)).count == pieces.count)
        #expect(copied.allSatisfy {
            $0.id != hidden.id && $0.localIdentifier == "local-hidden"
                && $0.cloudIdentifier == "cloud-hidden" && $0.hiddenAt == date(5)
        })
        #expect(try ModelContext(container).fetch(FetchDescriptor<PinnedPhoto>()).isEmpty)
        let decoded = try JSONDecoder().decode(
            DissolvedTripRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded.postSplitHolders == record.postSplitHolders)
        for holder in record.postSplitHolders ?? [] {
            #expect(Set(holder.inheritedHiddenPhotoIDs ?? [])
                    == Set(copied.filter { $0.tripID == holder.tripID }.map(\.id)))
        }
        #expect(await classifier.keepSplitTripWhole(record, pinnedTripIDs: []) == .kept)
        let restoredHidden = try ModelContext(container).fetch(FetchDescriptor<HiddenPhoto>())
        let restoredPinned = try ModelContext(container).fetch(FetchDescriptor<PinnedPhoto>())
        #expect(restoredHidden.map(\.id) == [hidden.id])
        #expect(restoredHidden.map(\.tripID) == [original.id])
        #expect(restoredPinned.map(\.id) == [pinned.id])
        #expect(restoredPinned.map(\.tripID) == [original.id])
        #expect(try membership(container) == [original.id: Set(members.map(\.id))])
    }

    @Test("unhiding an inherited photo is later user work: Keep blocks rather than re-hide it, and changes no graph or annotation rows")
    func unhidingInheritedPhotoBlocksKeep() async throws {
        let split = try await makeSplit()
        let ctx = ModelContext(split.container)
        let piece = try pieceHolding(split.ieper, split.container)
        let pieceID = piece.id
        let copied = try ctx.fetch(FetchDescriptor<HiddenPhoto>(
            predicate: #Predicate { $0.tripID == pieceID }))
        #expect(copied.count == 1)
        for row in copied { ctx.delete(row) }
        try ctx.save()
        let before = try storeState(split.container)
        #expect(await split.classifier.keepSplitTripWhole(split.record, pinnedTripIDs: [])
                == .blocked(reasons: [piece.displayName]))
        #expect(try storeState(split.container) == before)
    }

    @Test("removal may automatically regroup generated pieces but never restores the archive; explicit Keep can recover its original identity and name, and later user work still blocks", arguments: [false, true])
    func keepAfterRemovalRecoversOnlyUntouchedGeneratedGraph(renamed: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let (rowID, tripID) = try seedSemesterTrip(container, overriddenSide: false)
        let ctx = ModelContext(container)
        for row in try ctx.fetch(FetchDescriptor<HiddenPhoto>()) { ctx.delete(row) }
        let original = try #require(try ctx.fetch(FetchDescriptor<Trip>(
            predicate: #Predicate { $0.id == tripID })).first)
        original.customName = "Erasmus semester"
        try ctx.save()
        let classifier = await makeClassifier(container)
        let box = SplitRecordBox()
        await classifier.setDissolvedRecordSink { try box.append($0) }
        #expect(await reconcile(classifier, rowID, pinned: [tripID]).isSettled)
        let record = try #require(box.split.first)
        #expect(record.wasFavourite == true)
        let remove = ModelContext(container)
        for row in try remove.fetch(FetchDescriptor<TemporaryHome>(
            predicate: #Predicate { $0.id == rowID })) { row.removedAt = date(30) }
        try remove.save()
        #expect(await reconcile(classifier, rowID).isSettled)
        await ordinaryPass(classifier)
        #expect(try trips(withID: tripID, container).isEmpty)
        let generated = try #require(try stayRow(record.stays[0].id, container).trip)
        #expect(Set(generated.orderedStays.map(\.id)) == Set(record.stays.map(\.id)))
        #expect(record.postSplitHolders?.contains {
            $0.tripID == generated.id && Set($0.stayIDs) == Set(generated.orderedStays.map(\.id))
        } != true)
        if renamed {
            let edit = ModelContext(container)
            let generatedID = generated.id
            let piece = try #require(try edit.fetch(FetchDescriptor<Trip>(
                predicate: #Predicate { $0.id == generatedID })).first)
            piece.customName = "My new trip"
            try edit.save()
            let before = try storeState(container)
            #expect(await classifier.keepSplitTripWhole(record, pinnedTripIDs: [])
                    == .blocked(reasons: ["My new trip"]))
            #expect(try storeState(container) == before)
        } else {
            #expect(await classifier.keepSplitTripWhole(record, pinnedTripIDs: []) == .kept)
            let back = try #require(try trips(withID: tripID, container).first)
            #expect(back.customName == "Erasmus semester")
            #expect(back.orderedStays.map(\.id) == record.stays.map(\.id))
            #expect(back.orderedStays.allSatisfy { $0.temporaryHomeID == nil })
            #expect(try membership(container).count == 1)
            #expect(try ModelContext(container).fetch(FetchDescriptor<TemporaryHome>())
                    .allSatisfy { !$0.keptTripIDSet.contains(tripID) })
        }
    }

    @Test("Keep as One Trip after the temporary home's removal also puts back a trip that had a hidden photo, the photo hidden on it again")
    func keepAfterRemovalWithHiddenPhoto() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let (rowID, tripID) = try seedSemesterTrip(container, overriddenSide: false)
        let ctx = ModelContext(container)
        let original = try #require(try ctx.fetch(FetchDescriptor<Trip>(
            predicate: #Predicate { $0.id == tripID })).first)
        original.customName = "Erasmus semester"
        try ctx.save()
        let classifier = await makeClassifier(container)
        let box = SplitRecordBox()
        await classifier.setDissolvedRecordSink { try box.append($0) }
        #expect(await reconcile(classifier, rowID, pinned: [tripID]).isSettled)
        let record = try #require(box.split.first)
        let remove = ModelContext(container)
        for row in try remove.fetch(FetchDescriptor<TemporaryHome>(
            predicate: #Predicate { $0.id == rowID })) { row.removedAt = date(30) }
        try remove.save()
        #expect(await reconcile(classifier, rowID).isSettled)
        await ordinaryPass(classifier)

        #expect(await classifier.keepSplitTripWhole(record, pinnedTripIDs: []) == .kept)
        let back = try #require(try trips(withID: tripID, container).first)
        #expect(back.customName == "Erasmus semester")
        #expect(back.orderedStays.map(\.id) == record.stays.map(\.id))
        #expect(try ModelContext(container).fetch(FetchDescriptor<HiddenPhoto>())
                .contains { $0.tripID == tripID && $0.localIdentifier == "asset-1" })
    }

    @Test("Remove Temporary Home, queued as Settings queues it and run by the queue's drain, puts back the named favourite its covering split: whole under its id, its stays in order, its hidden photo and its favourite, with no piece the split made and no archive left; a piece the user renamed since blocks it, and the piece and the archive stay as they are",
          arguments: [false, true])
    func removalDrainPutsBackTheSplitTrip(renamedPiece: Bool) async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let (rowID, tripID) = try seedSemesterTrip(container, overriddenSide: false)
        let ctx = ModelContext(container)
        let original = try #require(try ctx.fetch(FetchDescriptor<Trip>(
            predicate: #Predicate { $0.id == tripID })).first)
        original.customName = "Erasmus semester"
        try ctx.save()
        let pins = PinnedTripsStorage(forTesting: defaults)
        pins.pin(tripID)
        let classifier = await makeClassifier(container)
        await classifier.setDissolvedRecordSink { try DissolvedTripQueue.append($0, in: directory) }
        func drainQueue() async {
            await StayClassificationInference.TestHook.$availability.withValue(false) {
                await self.drain(classifier, container, defaults: defaults, directory: directory, pins: pins)
            }
        }

        // The declaration's save queues its unit, which archives the trip and splits it.
        _ = CoverageReconciliationQueue.stage(.temporaryHome, id: rowID, defaults: defaults)
        await drainQueue()
        let record = try #require(DissolvedTripQueue.load(from: directory).first { $0.id == tripID })
        #expect(record.splitByTemporaryHomeID == rowID)
        #expect(record.splitCommitted == true)
        #expect(record.wasFavourite == true)
        #expect(try trips(withID: tripID, container).isEmpty)
        #expect(!pins.isPinned(tripID))
        let pieceIDs = (record.postSplitHolders ?? []).map(\.tripID)
        #expect(!pieceIDs.isEmpty)
        let sideTripPiece = try pieceHolding(record.stays[1].id, container).id
        #expect(pieceIDs.contains(sideTripPiece))
        if renamedPiece {
            let edit = ModelContext(container)
            let piece = try #require(try edit.fetch(FetchDescriptor<Trip>(
                predicate: #Predicate { $0.id == sideTripPiece })).first)
            piece.customName = "Ieper day"
            try edit.save()
        }

        // Remove Temporary Home, as Settings writes and queues it, then the drain.
        let removal = TemporaryHomeSaveWorker.apply(
            .removing(rowID, now: date(30)), context: ModelContext(container),
            pendingDefaults: defaults)
        #expect(!removal.failed)
        #expect(removal.pendingReconciliation?.id == rowID)
        await drainQueue()
        #expect(CoverageReconciliationQueue.pending(defaults: defaults).isEmpty)

        let queued = DissolvedTripQueue.load(from: directory).map(\.id)
        let backRows = try trips(withID: tripID, container)
        let hidden = try ModelContext(container).fetch(FetchDescriptor<HiddenPhoto>())
        if renamedPiece {
            // Later work blocks Keep: nothing comes back and the archive stays.
            #expect(try trips(withID: sideTripPiece, container).first?.customName == "Ieper day")
            #expect(backRows.isEmpty)
            #expect(queued == [tripID])
            #expect(!pins.isPinned(tripID))
        } else {
            #expect(backRows.count == 1)
            let back = try #require(backRows.first)
            #expect(back.customName == "Erasmus semester")
            #expect(back.orderedStays.map(\.id) == record.stays.map(\.id))
            #expect(try membership(container) == [tripID: Set(record.stays.map(\.id))])
            for pieceID in pieceIDs { #expect(try trips(withID: pieceID, container).isEmpty) }
            #expect(hidden.contains { $0.tripID == tripID && $0.localIdentifier == "asset-1" })
            #expect(hidden.allSatisfy { $0.tripID == tripID })
            #expect(pins.isPinned(tripID))
            #expect(queued.isEmpty)
        }
    }

    /// `removalDrainPutsBackTheSplitTrip`'s start: the named favourite with a
    /// hidden photo, its declaration queued and drained, which archived the
    /// trip in `directory` and split it.
    private func splitByTheDrain(
        directory: URL, defaults: UserDefaults
    ) async throws -> (container: ModelContainer, classifier: TripClassifier,
                       pins: PinnedTripsStorage, rowID: UUID, record: DissolvedTripRecord) {
        let container = try TestSupport.makeInMemoryContainer()
        let (rowID, tripID) = try seedSemesterTrip(container, overriddenSide: false)
        let ctx = ModelContext(container)
        let original = try #require(try ctx.fetch(FetchDescriptor<Trip>(
            predicate: #Predicate { $0.id == tripID })).first)
        original.customName = "Erasmus semester"
        try ctx.save()
        let pins = PinnedTripsStorage(forTesting: defaults)
        pins.pin(tripID)
        let classifier = await makeClassifier(container)
        await classifier.setDissolvedRecordSink { try DissolvedTripQueue.append($0, in: directory) }
        _ = CoverageReconciliationQueue.stage(.temporaryHome, id: rowID, defaults: defaults)
        await StayClassificationInference.TestHook.$availability.withValue(false) {
            await self.drain(classifier, container, defaults: defaults, directory: directory, pins: pins)
        }
        let record = try #require(DissolvedTripQueue.load(from: directory).first { $0.id == tripID })
        #expect(record.splitCommitted == true)
        #expect(try trips(withID: tripID, container).isEmpty)
        return (container, classifier, pins, rowID, record)
    }

    @Test("a removal whose putting back cannot finish, the Removed Trips queue unreadable or the Keep's save failing, leaves the trip in Removed Trips and the removal owed: the next drain runs it again and puts the trip back",
          arguments: [false, true])
    func unfinishedRemovalRestoreRunsAgain(unreadableQueue: Bool) async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let split = try await splitByTheDrain(directory: directory, defaults: defaults)
        let tripID = split.record.id
        func drainQueue() async {
            await StayClassificationInference.TestHook.$availability.withValue(false) {
                await self.drain(split.classifier, split.container, defaults: defaults,
                                 directory: directory, pins: split.pins)
            }
        }
        let queueURL = try #require(DissolvedTripQueue.fileURL(in: directory))
        if unreadableQueue {
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: queueURL.path)
        } else {
            await split.classifier.failNextDissolvedRestoreSave()
        }

        let removal = TemporaryHomeSaveWorker.apply(
            .removing(split.rowID, now: date(30)), context: ModelContext(split.container),
            pendingDefaults: defaults)
        #expect(!removal.failed)
        await drainQueue()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: queueURL.path)
        #expect(try trips(withID: tripID, split.container).isEmpty)
        #expect(DissolvedTripQueue.load(from: directory).map(\.id) == [tripID])

        await drainQueue()
        let back = try #require(try trips(withID: tripID, split.container).first)
        #expect(back.customName == "Erasmus semester")
        #expect(try membership(split.container) == [tripID: Set(split.record.stays.map(\.id))])
        #expect(split.pins.isPinned(tripID))
        #expect(DissolvedTripQueue.load(from: directory).isEmpty)
    }

    @Test("a removal hint an earlier drain left, equal to what the removed id's unit leaves, does not hold back a putting back whose Keep's save failed: the next drain runs it again and puts the trip back")
    func failedRemovalRestoreRunsAgainPastAnEarlierHint() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let split = try await splitByTheDrain(directory: directory, defaults: defaults)
        let tripID = split.record.id
        func drainQueue() async {
            await StayClassificationInference.TestHook.$availability.withValue(false) {
                await self.drain(split.classifier, split.container, defaults: defaults,
                                 directory: directory, pins: split.pins)
            }
        }
        func evidence() throws -> CoverageReconciliationQueue.RemovalEvidence? {
            try CoverageReconciliationQueue.removalEvidence(in: ModelContext(split.container))[split.rowID]
        }

        let removal = TemporaryHomeSaveWorker.apply(
            .removing(split.rowID, now: date(30)), context: ModelContext(split.container),
            pendingDefaults: defaults)
        #expect(!removal.failed)
        // An earlier unit for the removed id left its hint: what the unit leaves.
        #expect(await reconcile(split.classifier, split.rowID).isSettled)
        let left = try #require(try evidence())
        CoverageReconciliationQueue.recordRemovalHints([split.rowID: left], at: .now, defaults: defaults)
        await split.classifier.failNextDissolvedRestoreSave()
        await drainQueue()
        #expect(try evidence() == left)
        #expect(try trips(withID: tripID, split.container).isEmpty)
        #expect(DissolvedTripQueue.load(from: directory).map(\.id) == [tripID])

        await drainQueue()
        let back = try #require(try trips(withID: tripID, split.container).first)
        #expect(back.customName == "Erasmus semester")
        #expect(try membership(split.container) == [tripID: Set(split.record.stays.map(\.id))])
        #expect(split.pins.isPinned(tripID))
        #expect(DissolvedTripQueue.load(from: directory).isEmpty)
    }

    @Test("a removal hint an earlier drain left, equal to what the removed id's unit leaves, does not hold back a putting back that never started because the drain stopped after the unit settled (here its read of what the unit left fails, as an exit there would leave it): the entry is done, and the next drain runs the id again and puts the trip back")
    func settledRemovalRunsAgainPastAnEarlierHint() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let split = try await splitByTheDrain(directory: directory, defaults: defaults)
        let tripID = split.record.id
        func evidence() throws -> CoverageReconciliationQueue.RemovalEvidence? {
            try CoverageReconciliationQueue.removalEvidence(in: ModelContext(split.container))[split.rowID]
        }

        let removal = TemporaryHomeSaveWorker.apply(
            .removing(split.rowID, now: date(30)), context: ModelContext(split.container),
            pendingDefaults: defaults)
        #expect(!removal.failed)
        // An earlier unit for the removed id left its hint: what the unit leaves.
        #expect(await reconcile(split.classifier, split.rowID).isSettled)
        let left = try #require(try evidence())
        CoverageReconciliationQueue.recordRemovalHints([split.rowID: left], at: .now, defaults: defaults)
        // The drain's first read, before the units, succeeds; the one after them fails.
        let reads = EvidenceReads()
        await StayClassificationInference.TestHook.$availability.withValue(false) {
            await self.drain(split.classifier, split.container, defaults: defaults,
                             directory: directory, pins: split.pins) { stages in
                let read = stages.removalEvidence
                stages.removalEvidence = {
                    reads.count += 1
                    return reads.count == 1 ? read() : nil
                }
            }
        }
        #expect(reads.count == 2)
        #expect(CoverageReconciliationQueue.pending(defaults: defaults).isEmpty)
        #expect(try evidence() == left)
        #expect(try trips(withID: tripID, split.container).isEmpty)
        #expect(DissolvedTripQueue.load(from: directory).map(\.id) == [tripID])

        await StayClassificationInference.TestHook.$availability.withValue(false) {
            await self.drain(split.classifier, split.container, defaults: defaults,
                             directory: directory, pins: split.pins)
        }
        #expect(try trips(withID: tripID, split.container).count == 1)
        let back = try #require(try trips(withID: tripID, split.container).first)
        #expect(back.customName == "Erasmus semester")
        #expect(try membership(split.container) == [tripID: Set(split.record.stays.map(\.id))])
        #expect(split.pins.isPinned(tripID))
        #expect(DissolvedTripQueue.load(from: directory).isEmpty)
    }

    @Test("a real Home declared after the split that claims the trip's stays at the base holds them through the temporary home's removal: the drain's putting back leaves them home and the trip in Removed Trips, and Keep as One Trip from there stays the user's choice")
    func removalLeavesStaysARealHomeClaimsSince() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let split = try await splitByTheDrain(directory: directory, defaults: defaults)
        let tripID = split.record.id
        let base = [split.record.stays[0].id, split.record.stays[2].id]

        // The user moves to Brussels for real: a Home there, reconciled.
        let ctx = ModelContext(split.container)
        let home = Home(label: "Brussels", latitude: Self.brussels.lat, longitude: Self.brussels.lon,
                        radiusKm: 25, startedAt: date(10))
        ctx.insert(home)
        try ctx.save()
        let homeID = home.id
        #expect(await split.classifier.applyHomeChangeCore(homeID: homeID).isSettled)
        await ordinaryPass(split.classifier)
        func baseCategories() throws -> [StayCategory] {
            try base.map { try stayRow($0, split.container).category }
        }
        let claimed = try baseCategories()
        #expect(claimed == [.home, .home])

        let removal = TemporaryHomeSaveWorker.apply(
            .removing(split.rowID, now: date(30)), context: ModelContext(split.container),
            pendingDefaults: defaults)
        #expect(!removal.failed)
        await StayClassificationInference.TestHook.$availability.withValue(false) {
            await self.drain(split.classifier, split.container, defaults: defaults,
                             directory: directory, pins: split.pins)
        }
        #expect(CoverageReconciliationQueue.pending(defaults: defaults).isEmpty)
        let afterRemoval = try baseCategories()
        #expect(afterRemoval == [.home, .home])
        #expect(try trips(withID: tripID, split.container).isEmpty)
        #expect(DissolvedTripQueue.load(from: directory).map(\.id) == [tripID])
        #expect(!split.pins.isPinned(tripID))

        #expect(await split.classifier.keepSplitTripWhole(split.record, pinnedTripIDs: []) == .kept)
        #expect(try trips(withID: tripID, split.container).count == 1)
    }

    @Test("a real Home declared after the temporary home's removal whose unit reset the trip's stays at the base, and has not classified them yet, holds them against the removal's putting back: it blocks and nothing changes, and Keep as One Trip from there stays the user's choice")
    func removalKeepBlocksOnAHomeBetweenItsResetAndItsClassification() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let split = try await splitByTheDrain(directory: directory, defaults: defaults)
        let tripID = split.record.id
        let base = [split.record.stays[0].id, split.record.stays[2].id]

        // Remove Temporary Home: its unit commits; the putting back waits.
        let removal = TemporaryHomeSaveWorker.apply(
            .removing(split.rowID, now: date(30)), context: ModelContext(split.container),
            pendingDefaults: defaults)
        #expect(!removal.failed)
        #expect(await reconcile(split.classifier, split.rowID).isSettled)

        // The user moves to Brussels for real: the Home's unit resets the
        // stays at the base; its classification pass has not run.
        let ctx = ModelContext(split.container)
        let home = Home(label: "Brussels", latitude: Self.brussels.lat, longitude: Self.brussels.lon,
                        radiusKm: 25, startedAt: date(10))
        ctx.insert(home)
        try ctx.save()
        #expect(await split.classifier.applyHomeChangeCore(homeID: home.id).isSettled)
        let reset = try base.map { try stayRow($0, split.container) }
        #expect(reset.map(\.category) == [.unclassified, .unclassified])
        let expected = reset.map {
            $0.placeGroupName ?? $0.startTime.formatted(date: .abbreviated, time: .omitted)
        }

        let before = try storeState(split.container)
        let outcome = await split.classifier.keepSplitTripWhole(
            split.record, pinnedTripIDs: { [] }, gate: PipelineGate(forTesting: ()),
            queueDirectory: directory, removedTemporaryHomeIDs: [split.rowID], pin: { _ in })
        guard case .blocked(let reasons) = outcome else {
            Issue.record("the removal's Keep did not block: \(outcome)")
            return
        }
        #expect(reasons == expected)
        #expect(try storeState(split.container) == before)
        #expect(DissolvedTripQueue.load(from: directory).map(\.id) == [tripID])

        #expect(await split.classifier.keepSplitTripWhole(split.record, pinnedTripIDs: []) == .kept)
        #expect(try trips(withID: tripID, split.container).count == 1)
    }

    @Test("the removal's putting back acts only on a committed split of a removed temporary home, read again inside its gate: when the archive it was handed was kept since and a live temporary home split the trip again, the newer archive under that id stays in Removed Trips and nothing changes")
    func removalKeepSkipsANewerArchiveOfALiveSplit() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let (rowID, tripID) = try seedSemesterTrip(container, overriddenSide: false)
        let classifier = await makeClassifier(container)
        await classifier.setDissolvedRecordSink { try DissolvedTripQueue.append($0, in: directory) }
        #expect(await reconcile(classifier, rowID, pinned: [tripID]).isSettled)
        let stale = try #require(DissolvedTripQueue.load(from: directory).first { $0.id == tripID })
        let remove = ModelContext(container)
        for row in try remove.fetch(FetchDescriptor<TemporaryHome>(
            predicate: #Predicate { $0.id == rowID })) { row.removedAt = date(30) }
        try remove.save()
        #expect(await reconcile(classifier, rowID).isSettled)
        await ordinaryPass(classifier)

        // The user keeps it as one trip, then a live temporary home splits it again.
        let pins = PinnedTripsStorage(forTesting: defaults)
        let kept = await StayClassificationInference.TestHook.$availability.withValue(false) {
            await HomeAreaHealing.keepSplitTrip(
                stale, classifier: classifier, gate: PipelineGate(forTesting: ()),
                pins: pins, queueDirectory: directory)
        }
        #expect(kept == .kept)
        let declare = ModelContext(container)
        let liveID = temporaryHome(declare).id
        try declare.save()
        #expect(await reconcile(classifier, liveID).isSettled)
        let newer = try #require(DissolvedTripQueue.load(from: directory).first { $0.id == tripID })
        #expect(newer.splitByTemporaryHomeID == liveID)
        #expect(newer.splitCommitted == true)
        #expect(try trips(withID: tripID, container).isEmpty)

        // The removal's Keep, handed the archive it read before.
        let before = try storeState(container)
        let outcome = await classifier.keepSplitTripWhole(
            stale, pinnedTripIDs: { [] }, gate: PipelineGate(forTesting: ()),
            queueDirectory: directory, removedTemporaryHomeIDs: [rowID], pin: { _ in })
        #expect(outcome == .staysMissing)
        #expect(try storeState(container) == before)
        #expect(DissolvedTripQueue.load(from: directory) == [newer])
        #expect(try ModelContext(container).fetch(FetchDescriptor<TemporaryHome>(
            predicate: #Predicate { $0.id == liveID })).allSatisfy { $0.keptTripIDSet.isEmpty })
    }

    @Test("Keep as One Trip after the temporary home's removal blocks, naming it and changing nothing, on the regrouped trip another live temporary home keeps explicitly, though it is no longer a favourite")
    func keepAfterRemovalBlocksOnAnotherHomesKeptTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let (rowID, tripID) = try seedSemesterTrip(container, overriddenSide: false)
        let ctx = ModelContext(container)
        for row in try ctx.fetch(FetchDescriptor<HiddenPhoto>()) { ctx.delete(row) }
        try ctx.save()
        let classifier = await makeClassifier(container)
        let box = SplitRecordBox()
        await classifier.setDissolvedRecordSink { try box.append($0) }
        #expect(await reconcile(classifier, rowID, pinned: [tripID]).isSettled)
        let original = try #require(box.split.first { $0.id == tripID })
        let remove = ModelContext(container)
        for row in try remove.fetch(FetchDescriptor<TemporaryHome>(
            predicate: #Predicate { $0.id == rowID })) { row.removedAt = date(30) }
        try remove.save()
        #expect(await reconcile(classifier, rowID).isSettled)
        await ordinaryPass(classifier)
        let regrouped = try #require(try stayRow(original.stays[0].id, container).trip)
        let regroupedID = regrouped.id
        #expect(Set(regrouped.orderedStays.map(\.id)) == Set(original.stays.map(\.id)))

        // A second temporary home covers part of the favourite regrouped trip,
        // which the user then keeps as one trip against it.
        let declare = ModelContext(container)
        let secondID = temporaryHome(declare).id
        try declare.save()
        #expect(await reconcile(classifier, secondID, pinned: [regroupedID]).isSettled)
        let regroupedRecord = try #require(box.split.first { $0.id == regroupedID })
        #expect(try trips(withID: regroupedID, container).isEmpty)
        #expect(await classifier.keepSplitTripWhole(regroupedRecord, pinnedTripIDs: []) == .kept)
        let kept = try #require(try trips(withID: regroupedID, container).first)
        #expect(kept.userEdited && kept.keptByTemporaryHome)
        let keptName = kept.displayName
        func secondKeeps() throws -> Bool {
            let rows = try ModelContext(container).fetch(FetchDescriptor<TemporaryHome>(
                predicate: #Predicate { $0.id == secondID }))
            return !rows.isEmpty && rows.allSatisfy { $0.removedAt == nil && $0.keptTripIDSet == [regroupedID] }
        }
        #expect(try secondKeeps())

        // Unfavourited: Keep on the first archive is handed no favourites.
        let before = try storeState(container)
        let outcome = await classifier.keepSplitTripWhole(original, pinnedTripIDs: [])
        #expect(outcome == .blocked(reasons: [keptName]))
        let after = try storeState(container)
        #expect(after == before)
        let regroupedRows = try trips(withID: regroupedID, container).count
        let originalRows = try trips(withID: tripID, container).count
        #expect(regroupedRows == 1)
        #expect(originalRows == 0)
        let stillKept = try secondKeeps()
        #expect(stillKept)
    }

    @Test("a shared generated piece carrying hidden choices from two archives blocks both Keeps even after same-photo dedup, preserving the other archive's privacy choice", arguments: [false, true])
    func sharedHolderDoesNotEraseAnotherArchivesHide(samePhoto: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        let first = trip(ctx, [stay(ctx, Self.brussels, 10.2, 10.8, .destination),
                               stay(ctx, Self.ieper, 11.2, 11.8, .destination)])
        let second = trip(ctx, [stay(ctx, Self.bedburg, 12.2, 12.8, .destination),
                                stay(ctx, Self.brussels, 13.2, 13.8, .destination)])
        stay(ctx, Self.athens, 16.2, 20, .home)
        let firstHide = HiddenPhoto(localIdentifier: "first-hidden", tripID: first.id)
        let secondHide = HiddenPhoto(localIdentifier: "second-hidden", tripID: second.id)
        if samePhoto {
            firstHide.cloudIdentifier = "shared-cloud-photo"
            secondHide.cloudIdentifier = "shared-cloud-photo"
        }
        ctx.insert(firstHide)
        ctx.insert(secondHide)
        let row = temporaryHome(ctx)
        try ctx.save()
        let classifier = await makeClassifier(container)
        let box = SplitRecordBox()
        await classifier.setDissolvedRecordSink { try box.append($0) }
        #expect(await reconcile(classifier, row.id).isSettled)
        #expect(box.split.count == 2)
        #expect(try membership(container).count == 1)
        let copied = try ModelContext(container).fetch(FetchDescriptor<HiddenPhoto>())
        #expect(copied.count == 2)
        #expect(Set(copied.map(\.tripID)).count == 1)
        #expect(await PhotoAnnotationDeduplicator.deduplicateAll(modelContainer: container))
        #expect(try ModelContext(container).fetch(FetchDescriptor<HiddenPhoto>()).count == (samePhoto ? 1 : 2))
        let before = try storeState(container)
        for record in box.split {
            #expect(record.postSplitHolders?.first?.inheritedHiddenPhotoIDs?.count == 1)
            #expect(record.postSplitHolders?.first?.sharesInheritedHiddenPhotos == true)
            guard case .blocked = await classifier.keepSplitTripWhole(record, pinnedTripIDs: []) else {
                Issue.record("Keep discarded another archive's inherited hiding choice")
                continue
            }
            #expect(try storeState(container) == before)
        }
    }

    @Test("duplicate archived hides produce one inherited row per logical photo, so normal dedup does not block an untouched Keep")
    func duplicateArchivedHidesDoNotBlockKeep() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let (rowID, tripID) = try seedSemesterTrip(container)
        let ctx = ModelContext(container)
        let original = try #require(try ctx.fetch(FetchDescriptor<HiddenPhoto>()).first)
        original.cloudIdentifier = "same-cloud-photo"
        let twin = HiddenPhoto(localIdentifier: original.localIdentifier, tripID: tripID)
        twin.id = original.id
        twin.hiddenAt = original.hiddenAt
        twin.cloudIdentifier = original.cloudIdentifier
        ctx.insert(twin)
        try ctx.save()
        let classifier = await makeClassifier(container)
        let box = SplitRecordBox()
        await classifier.setDissolvedRecordSink { try box.append($0) }
        #expect(await reconcile(classifier, rowID).isSettled)
        let record = try #require(box.split.first)
        #expect(record.photoAnnotations?.count == 2)
        let copied = try ModelContext(container).fetch(FetchDescriptor<HiddenPhoto>())
        #expect(copied.count == 1)
        #expect(record.postSplitHolders?.first?.inheritedHiddenPhotoIDs == copied.map(\.id))
        #expect(await PhotoAnnotationDeduplicator.deduplicateAll(modelContainer: container))
        #expect(try ModelContext(container).fetch(FetchDescriptor<HiddenPhoto>()).map(\.id) == copied.map(\.id))
        #expect(await classifier.keepSplitTripWhole(record, pinnedTripIDs: []) == .kept)
        let returned = try ModelContext(container).fetch(FetchDescriptor<HiddenPhoto>())
        #expect(!returned.isEmpty)
        #expect(returned.allSatisfy {
            $0.id == original.id && $0.tripID == tripID
                && $0.localIdentifier == original.localIdentifier
                && $0.cloudIdentifier == "same-cloud-photo"
        })
        #expect(try trips(withID: tripID, container).count == 1)
    }

    @Test("a photo hidden twice on the original, once before its cloud id was known, is one inherited row per piece, so cloud-id backfill and dedup do not block an untouched Keep, which restores every archived row; with the other hide synced from another device, the photo's archived pin carries its cloud id",
          arguments: [false, true])
    func backfilledDuplicateHideDoesNotBlockKeep(otherDevice: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let (rowID, tripID) = try seedSemesterTrip(container)
        let ctx = ModelContext(container)
        let local = try #require(try ctx.fetch(FetchDescriptor<HiddenPhoto>()).first)
        #expect(local.cloudIdentifier == nil)
        let elsewhere = otherDevice ? "asset-1-other-device" : local.localIdentifier
        let cloud = HiddenPhoto(localIdentifier: elsewhere, tripID: tripID)
        cloud.cloudIdentifier = "cloud-C"
        ctx.insert(cloud)
        var pinIDs: [UUID] = []
        if otherDevice {
            let pin = PinnedPhoto(localIdentifier: local.localIdentifier, tripID: tripID)
            pin.cloudIdentifier = "cloud-C"
            ctx.insert(pin)
            pinIDs = [pin.id]
        }
        try ctx.save()
        let hiddenIDs: Set<UUID> = [local.id, cloud.id]
        let archivedIDs = hiddenIDs.union(pinIDs)
        let classifier = await makeClassifier(container)
        let box = SplitRecordBox()
        await classifier.setDissolvedRecordSink { try box.append($0) }
        #expect(await reconcile(classifier, rowID).isSettled)
        let record = try #require(box.split.first)
        #expect(Set((record.photoAnnotations ?? []).map(\.id)) == archivedIDs)
        let pieces = try membership(container)
        let inherited = try ModelContext(container).fetch(FetchDescriptor<HiddenPhoto>())
        #expect(inherited.count == pieces.count)

        // What PhotoService's cloud-id backfill does to the pieces' rows.
        let backfill = ModelContext(container)
        for row in try backfill.fetch(FetchDescriptor<HiddenPhoto>())
        where row.cloudIdentifier == nil && row.localIdentifier == "asset-1" {
            row.cloudIdentifier = "cloud-C"
        }
        try backfill.save()
        #expect(await PhotoAnnotationDeduplicator.deduplicateAll(modelContainer: container))
        let outcome = await classifier.keepSplitTripWhole(record, pinnedTripIDs: [])
        #expect(outcome == .kept)
        let returned = try ModelContext(container).fetch(FetchDescriptor<HiddenPhoto>())
        #expect(Set(returned.map(\.id)) == hiddenIDs)
        #expect(returned.count == 2)
        #expect(returned.allSatisfy { $0.tripID == tripID })
        #expect(returned.first { $0.id == local.id }?.localIdentifier == "asset-1")
        #expect(returned.first { $0.id == local.id }?.cloudIdentifier == nil)
        #expect(returned.first { $0.id == cloud.id }?.localIdentifier == elsewhere)
        #expect(returned.first { $0.id == cloud.id }?.cloudIdentifier == "cloud-C")
        let pins = try ModelContext(container).fetch(FetchDescriptor<PinnedPhoto>())
        #expect(pins.map(\.id) == pinIDs)
        #expect(pins.allSatisfy { $0.tripID == tripID && $0.cloudIdentifier == "cloud-C" })
        #expect(try trips(withID: tripID, container).count == 1)
    }

    @Test("dedup may replace an inherited hidden row while keeping the logical hide; Keep then blocks conservatively and leaves that choice intact")
    func replacedInheritedPhotoBlocksKeep() async throws {
        let split = try await makeSplit()
        let ctx = ModelContext(split.container)
        let piece = try pieceHolding(split.ieper, split.container)
        let inheritedID = try #require(split.record.postSplitHolders?.first?.inheritedHiddenPhotoIDs?.first)
        let replacement = HiddenPhoto(localIdentifier: "asset-1", tripID: piece.id)
        replacement.hiddenAt = date(1)
        ctx.insert(replacement)
        try ctx.save()
        #expect(await PhotoAnnotationDeduplicator.deduplicateAll(modelContainer: split.container))
        let rows = try ModelContext(split.container).fetch(FetchDescriptor<HiddenPhoto>())
        #expect(rows.map(\.id) == [replacement.id])
        #expect(rows.first?.id != inheritedID)
        let before = try storeState(split.container)
        #expect(await split.classifier.keepSplitTripWhole(split.record, pinnedTripIDs: [])
                == .blocked(reasons: [piece.displayName]))
        #expect(try storeState(split.container) == before)
    }

    @Test("a hidden row arriving late under the retired original id survives Keep beside the archived choices")
    func lateOriginalPhotoChoiceSurvivesKeep() async throws {
        let split = try await makeSplit()
        let ctx = ModelContext(split.container)
        let late = HiddenPhoto(localIdentifier: "late-local", tripID: split.tripID)
        late.cloudIdentifier = "late-cloud"
        ctx.insert(late)
        try ctx.save()
        #expect(await split.classifier.keepSplitTripWhole(split.record, pinnedTripIDs: []) == .kept)
        let rows = try ModelContext(split.container).fetch(FetchDescriptor<HiddenPhoto>())
        #expect(Set(rows.map(\.localIdentifier)) == ["asset-1", "late-local"])
        #expect(Set(rows.map(\.tripID)) == [split.tripID])
        let keptLate = try #require(rows.first { $0.id == late.id })
        #expect(keptLate.cloudIdentifier == "late-cloud")
    }

    @Test("a hidden photo and a favourite another device gave a piece before it saw Keep as One Trip follow the kept trip once they sync in, rather than aging out with the piece")
    func latePieceChoicesFollowKeep() async throws {
        let split = try await makeSplit()
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pieceID = try pieceHolding(split.ieper, split.container).id
        #expect(await split.classifier.keepSplitTripWhole(
            split.record, pinnedTripIDs: [], defaults: UserDefaults(suiteName: suite)!) == .kept)
        #expect(try trips(withID: pieceID, split.container).isEmpty)

        let ctx = ModelContext(split.container)
        let late = HiddenPhoto(localIdentifier: "late-on-piece", tripID: pieceID)
        ctx.insert(late)
        try ctx.save()
        let now = Date.now
        for sweepAt in [now, now.addingTimeInterval(25 * 60 * 60)] {
            #expect(await PhotoAnnotationDeduplicator.sweepOrphans(
                modelContainer: split.container, now: sweepAt, defaults: defaults,
                queueDirectory: directory).completed)
        }
        let rows = try ModelContext(split.container).fetch(FetchDescriptor<HiddenPhoto>())
        #expect(rows.first { $0.id == late.id }?.tripID == split.tripID)

        PinnedTripsStorage(forTesting: defaults).pin(pieceID)
        let pins = PinnedTripsStorage(forTesting: defaults)
        await TripDeduplicator.rekeyCarriedFavourites(
            modelContainer: split.container, defaults: defaults, pins: pins)
        #expect(pins.pinnedIDs == [split.tripID])
    }

    @Test("Keep removes inherited copies when all populated piece twins go, and logs the piece as carried onto the kept trip; it preserves them, and carries nothing, when an unrelated populated twin survives", arguments: [false, true])
    func keepCleansInheritedRowsWithPopulatedTwins(survives: Bool) async throws {
        let split = try await makeSplit(overriddenSide: false)
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let ctx = ModelContext(split.container)
        let piece = try pieceHolding(split.ieper, split.container)
        let twinMember: Stay
        if survives {
            twinMember = stay(ctx, Self.vienna, 50.2, 50.8, .destination)
        } else {
            let baseID = split.base[0]
            twinMember = try #require(try ctx.fetch(FetchDescriptor<Stay>(
                predicate: #Predicate { $0.id == baseID })).first)
            for row in try ctx.fetch(FetchDescriptor<TemporaryHome>()) { row.removedAt = date(30) }
        }
        let twin = trip(ctx, [twinMember])
        twin.id = piece.id
        try ctx.save()
        #expect(await split.classifier.keepSplitTripWhole(
            split.record, pinnedTripIDs: [], defaults: UserDefaults(suiteName: suite)!) == .kept)
        let rows = try ModelContext(split.container).fetch(FetchDescriptor<HiddenPhoto>())
        #expect(rows.count == (survives ? 2 : 1))
        #expect(Set(rows.map(\.tripID)) == (survives ? [split.tripID, piece.id] : [split.tripID]))
        #expect(try trips(withID: piece.id, split.container).count == (survives ? 1 : 0))
        if survives { #expect(try stayRow(twinMember.id, split.container).trip?.id == piece.id) }
        #expect(TripDeduplicator.carriedWinners(defaults: defaults)[piece.id] == (survives ? nil : split.tripID))
    }

    nonisolated enum LaterWork: String, CaseIterable, Sendable {
        case renamedPiece, favouritedPiece, photoOnPiece, editedPiece, setBaseStay
    }

    @Test("work done since the split blocks Keep as One Trip and changes nothing, and names what blocks it: a piece renamed, favourited, given a photo choice or edited, or a recorded stay set by the user",
          arguments: LaterWork.allCases)
    func laterWorkBlocksKeep(work: LaterWork) async throws {
        // The edit needs a piece the split left unedited: its side trip is
        // not a stay the user set.
        let split = try await makeSplit(overriddenSide: work != .editedPiece)
        let container = split.container
        let ctx = ModelContext(container)
        let pieceID = try pieceHolding(split.ieper, container).id
        let piece = try #require(try ctx.fetch(FetchDescriptor<Trip>(
            predicate: #Predicate { $0.id == pieceID })).first)
        var pinned: Set<UUID> = []
        var expected: String
        switch work {
        case .renamedPiece:
            piece.customName = "Ieper day"
            expected = "Ieper day"
        case .favouritedPiece:
            pinned = [pieceID]
            expected = piece.displayName
        case .photoOnPiece:
            ctx.insert(PinnedPhoto(localIdentifier: "asset-7", tripID: pieceID))
            expected = piece.displayName
        case .editedPiece:
            // As the split left it, and as its archive says.
            #expect(!piece.userEdited && !piece.keptByTemporaryHome)
            #expect(split.record.postSplitHolders?.first { $0.tripID == pieceID }?.userEdited == false)
            expected = ""
        case .setBaseStay:
            let baseID = split.base[0]
            let base = try #require(try ctx.fetch(FetchDescriptor<Stay>(
                predicate: #Predicate { $0.id == baseID })).first)
            base.category = .destination
            base.userOverridden = true
            base.locality = "Ixelles"
            expected = "Ixelles"
        }
        try ctx.save()
        if work == .editedPiece {
            // The user merges a later trip into the piece from the Trips list.
            let lone = stay(ctx, Self.vienna, 50.2, 50.8, .destination)
            let later = trip(ctx, [lone])
            try ctx.save()
            #expect(TripsListView.mergeTrips(
                sourceID: later.id, sourceIdentifier: later.persistentModelID,
                targetID: pieceID, targetIdentifier: piece.persistentModelID,
                container: container))
            let edited = try #require(try trips(withID: pieceID, container).first)
            #expect(edited.userEdited && !edited.keptByTemporaryHome)
            #expect(Set((edited.stays ?? []).map(\.id)) == [split.ieper, lone.id])
            expected = edited.displayName
        }
        let before = try storeState(container)
        #expect(await split.classifier.keepSplitTripWhole(split.record, pinnedTripIDs: pinned)
                == .blocked(reasons: [expected]))
        #expect(try storeState(container) == before)
        #expect(try trips(withID: split.tripID, container).isEmpty)
    }

    @Test("a piece the split made edited, because it holds a stay the user had set, is not later work by itself, so its archive says it was edited; a later change to that stay on the piece's own screen blocks Keep as One Trip, naming the stay, and changes nothing")
    func laterEditOfAPieceEditedFromBirthBlocksKeep() async throws {
        let split = try await makeSplit()
        let container = split.container
        let piece = try pieceHolding(split.ieper, container)
        let pieceID = piece.id
        #expect(piece.userEdited && !piece.keptByTemporaryHome)
        #expect(split.record.postSplitHolders?.first { $0.tripID == pieceID }?.userEdited == true)

        let stay = try stayRow(split.ieper, container)
        #expect(TripDetailView.applyCategoryChange(
            stayID: split.ieper, stayIdentifier: stay.persistentModelID,
            tripID: pieceID, tripIdentifier: piece.persistentModelID,
            newCategory: .transit, in: ModelContext(container)))
        let changed = try stayRow(split.ieper, container)
        #expect(changed.category == .transit)
        #expect(changed.userOverridden)
        let expected = changed.placeGroupName
            ?? changed.startTime.formatted(date: .abbreviated, time: .omitted)
        let before = try storeState(container)
        #expect(await split.classifier.keepSplitTripWhole(split.record, pinnedTripIDs: [])
                == .blocked(reasons: [expected]))
        #expect(try storeState(container) == before)
        #expect(try trips(withID: split.tripID, container).isEmpty)
    }

    @Test("a stay the split left as the user set it, then given back to Automatic, blocks Keep as One Trip, naming the stay: putting the trip back would set it again; nothing changes")
    func automaticSinceTheSplitBlocksKeep() async throws {
        let split = try await makeSplit()
        let container = split.container
        let ref = try #require(split.record.stays.first { $0.id == split.ieper })
        #expect(ref.postSplitOverridden == true)

        let reset = await StayClassificationInference.TestHook.$availability.withValue(false) {
            await split.classifier.resetStayToAutomatic(
                stayID: split.ieper, gate: PipelineGate(forTesting: ()), stage: { _ in }, drain: {})
        }
        #expect(reset)
        let automatic = try stayRow(split.ieper, container)
        #expect(!automatic.userOverridden)
        let expected = automatic.placeGroupName
            ?? automatic.startTime.formatted(date: .abbreviated, time: .omitted)

        let before = try storeState(container)
        let outcome = await split.classifier.keepSplitTripWhole(split.record, pinnedTripIDs: [])
        guard case .blocked(let reasons) = outcome else {
            Issue.record("Keep as One Trip did not block: \(outcome)")
            return
        }
        #expect(reasons.contains(expected))
        #expect(try storeState(container) == before)
        #expect(try !stayRow(split.ieper, container).userOverridden)
        #expect(try trips(withID: split.tripID, container).isEmpty)
    }

    @Test("a piece the split made edited, because it holds a stay the user had set, into which the user then merges another trip from the Trips list, blocks Keep as One Trip, naming it: its stays changed since the split, whatever its edit mark; nothing changes")
    func mergeIntoAPieceEditedFromBirthBlocksKeep() async throws {
        let split = try await makeSplit()
        let container = split.container
        let ctx = ModelContext(container)
        let pieceID = try pieceHolding(split.ieper, container).id
        let piece = try #require(try ctx.fetch(FetchDescriptor<Trip>(
            predicate: #Predicate { $0.id == pieceID })).first)
        #expect(piece.userEdited && !piece.keptByTemporaryHome)
        #expect(split.record.postSplitHolders?.first { $0.tripID == pieceID }?.userEdited == true)

        let lone = stay(ctx, Self.vienna, 50.2, 50.8, .destination)
        let later = trip(ctx, [lone])
        try ctx.save()
        #expect(TripsListView.mergeTrips(
            sourceID: later.id, sourceIdentifier: later.persistentModelID,
            targetID: pieceID, targetIdentifier: piece.persistentModelID,
            container: container))
        let merged = try #require(try trips(withID: pieceID, container).first)
        #expect(Set((merged.stays ?? []).map(\.id)) == [split.ieper, lone.id])
        let expected = merged.displayName

        let before = try storeState(container)
        #expect(await split.classifier.keepSplitTripWhole(split.record, pinnedTripIDs: [])
                == .blocked(reasons: [expected]))
        #expect(try storeState(container) == before)
        #expect(try trips(withID: split.tripID, container).isEmpty)
    }

    @Test("Keep as One Trip blocks, naming it and changing nothing, when a recorded stay is now held by a trip the split did not make")
    func keepBlocksOnATripTheSplitDidNotMake() async throws {
        let split = try await makeSplit()
        let container = split.container
        let ctx = ModelContext(container)
        // A trip that arrived since (sync, an import) now holds the side trip's stay.
        let ieperID = split.ieper
        let side = try #require(try ctx.fetch(FetchDescriptor<Stay>(
            predicate: #Predicate { $0.id == ieperID })).first)
        let arrived = trip(ctx, [side])
        try ctx.save()
        let expected = try #require(try trips(withID: arrived.id, container).first).displayName
        let before = try storeState(container)
        #expect(await split.classifier.keepSplitTripWhole(split.record, pinnedTripIDs: [])
                == .blocked(reasons: [expected]))
        #expect(try storeState(container) == before)
    }

    @Test("Keep as One Trip blocks, naming the piece and changing nothing, when a piece holding another trip's stay has that stay set by the user since the split")
    func keepBlocksOnAStayTheUserSetOnAPiece() async throws {
        let fixture = try await makePartialHolder()
        let ctx = ModelContext(fixture.container)
        let neighbourID = fixture.neighbour
        let neighbour = try #require(try ctx.fetch(FetchDescriptor<Stay>(
            predicate: #Predicate { $0.id == neighbourID })).first)
        neighbour.userOverridden = true
        try ctx.save()
        let expected = try pieceHolding(neighbourID, fixture.container).displayName
        let before = try storeState(fixture.container)
        #expect(await fixture.classifier.keepSplitTripWhole(fixture.record, pinnedTripIDs: [])
                == .blocked(reasons: [expected]))
        #expect(try storeState(fixture.container) == before)
    }

    @Test("Keep as One Trip keeps the archive when a recorded stay is missing or has a twin row, and changes nothing")
    func missingOrAmbiguousStaysKeepTheRecord() async throws {
        let split = try await makeSplit()
        let container = split.container
        let ctx = ModelContext(container)
        let twinOf = try stayRow(split.base[1], container)
        let twin = Stay(
            startTime: twinOf.startTime, endTime: twinOf.endTime,
            centroidLatitude: twinOf.centroidLatitude, centroidLongitude: twinOf.centroidLongitude,
            h3IndexRes6: "S", pingCount: 2, distanceFromHomeKm: 0, pingIDs: [])
        twin.id = twinOf.id
        ctx.insert(twin)
        try ctx.save()
        var before = try storeState(container)
        #expect(await split.classifier.keepSplitTripWhole(split.record, pinnedTripIDs: []) == .staysAmbiguous)
        #expect(try storeState(container) == before)

        let missingID = split.base[0]
        for stay in try ctx.fetch(FetchDescriptor<Stay>(predicate: #Predicate { $0.id == missingID })) {
            ctx.delete(stay)
        }
        try ctx.save()
        before = try storeState(container)
        #expect(await split.classifier.keepSplitTripWhole(split.record, pinnedTripIDs: []) == .staysMissing)
        #expect(try storeState(container) == before)
    }

    /// A named trip to the base with a side trip to Ieper, and another trip
    /// right after it with no home stay between, split by a new temporary home.
    private struct PartialHolder {
        let container: ModelContainer
        let classifier: TripClassifier
        let namedID: UUID
        let otherID: UUID
        let members: [UUID]
        let neighbour: UUID
        let record: DissolvedTripRecord
    }

    private func makePartialHolder() async throws -> PartialHolder {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        let members = [stay(ctx, Self.brussels, 10.2, 12.8, .destination),
                       stay(ctx, Self.ieper, 13.2, 13.8, .destination)]
        // Another trip right after, with no home stay between.
        let neighbour = stay(ctx, Self.bedburg, 14.2, 14.8, .destination)
        stay(ctx, Self.athens, 16.2, 20, .home)
        let named = trip(ctx, members)
        named.customName = "Erasmus"
        let other = trip(ctx, [neighbour])
        let row = temporaryHome(ctx, until: 100)
        try ctx.save()
        let (namedID, otherID) = (named.id, other.id)

        let classifier = await makeClassifier(container)
        let box = SplitRecordBox()
        await classifier.setDissolvedRecordSink { try box.append($0) }
        #expect(await reconcile(classifier, row.id).isSettled)
        return PartialHolder(
            container: container, classifier: classifier, namedID: namedID, otherID: otherID,
            members: members.map(\.id), neighbour: neighbour.id,
            record: try #require(box.split.first))
    }

    @Test("a piece that also holds another trip's stay goes with Keep as One Trip: the recorded stays come back to the kept trip and the other stay is regrouped by the next pass")
    func partialHolderIsRegrouped() async throws {
        let fixture = try await makePartialHolder()
        let (container, classifier) = (fixture.container, fixture.classifier)
        let (namedID, members, neighbour) = (fixture.namedID, fixture.members, fixture.neighbour)
        // One piece holds the side trip and the neighbour; a split piece takes no constituent's id.
        let pieces = try membership(container)
        #expect(pieces.count == 1)
        #expect(pieces.values.first == [members[1], neighbour])
        #expect(pieces[fixture.otherID] == nil && pieces[namedID] == nil)

        #expect(await classifier.keepSplitTripWhole(fixture.record, pinnedTripIDs: []) == .kept)
        #expect(try membership(container) == [namedID: Set(members)])
        #expect(try stayRow(neighbour, container).trip == nil)
        await ordinaryPass(classifier)
        let regrouped = try membership(container)
        #expect(regrouped[namedID] == Set(members))
        #expect(regrouped.count == 2)
        #expect(regrouped.values.contains([neighbour]))
    }

    @Test("Keep as One Trip's regrouping of a piece's other stays waits for a pass already running instead of being dropped: once that pass lets go, the other stay is a trip of its own again, with its dates")
    func keepRegroupWaitsForARunningPass() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = try await makePartialHolder()
        let (container, classifier, record) = (fixture.container, fixture.classifier, fixture.record)
        try enqueue(record, in: directory)
        let pins = PinnedTripsStorage(forTesting: defaults)

        // Another operation holds the pipeline, as one generating titles does.
        await classifier.setRunningLatchForTesting(true)
        let progress = KeepProgress()
        let keep = Task { @MainActor in
            let outcome = await StayClassificationInference.TestHook.$availability.withValue(false) {
                await TripClassifier.QueueTestHook.$waiting.withValue({ progress.markWaiting() }) {
                    await HomeAreaHealing.keepSplitTrip(
                        record, classifier: classifier, gate: PipelineGate(forTesting: ()),
                        pins: pins, queueDirectory: directory)
                }
            }
            progress.markFinished()
            return outcome
        }
        var spins = 0
        while !progress.settled && spins < 400 {
            try await Task.sleep(for: .milliseconds(25))
            spins += 1
        }
        await classifier.setRunningLatchForTesting(false)
        #expect(await keep.value == .kept)

        #expect(try membership(container)[fixture.namedID] == Set(fixture.members))
        let regrouped = try #require(try stayRow(fixture.neighbour, container).trip)
        #expect(Set((regrouped.stays ?? []).map(\.id)) == [fixture.neighbour])
        #expect(regrouped.startDate == date(14.2))
        #expect(regrouped.endDate == date(14.8))
        #expect(regrouped.isComplete)
    }

    @Test("a split trip's stay away from the base right after a named open trip the user edited is a piece of its own, never adopted into that trip: the trip keeps its id, name and stays through the split and through Keep as One Trip")
    func splitRemnantIsNotAdoptedByAnEditedOpenTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        let earlier = stay(ctx, Self.bedburg, 10.2, 10.8, .destination)
        let members = [stay(ctx, Self.ieper, 11.2, 11.8, .destination),
                       stay(ctx, Self.brussels, 12.2, 14.8, .destination)]
        let open = trip(ctx, [earlier], complete: false)
        open.customName = "Weekend"
        open.userEdited = true
        let named = trip(ctx, members)
        named.customName = "Erasmus"
        let row = temporaryHome(ctx, until: 100)
        try ctx.save()
        let (openID, namedID) = (open.id, named.id)

        let classifier = await makeClassifier(container)
        let box = SplitRecordBox()
        await classifier.setDissolvedRecordSink { try box.append($0) }
        #expect(await reconcile(classifier, row.id).isSettled)
        let afterSplit = try membership(container)
        #expect(afterSplit[openID] == [earlier.id])
        #expect(afterSplit[namedID] == nil)
        #expect(afterSplit.values.contains([members[0].id]))
        let still = try #require(try trips(withID: openID, container).first)
        #expect(still.customName == "Weekend")
        #expect(still.userEdited)

        let record = try #require(box.split.first)
        #expect(await classifier.keepSplitTripWhole(record, pinnedTripIDs: []) == .kept)
        let afterKeep = try membership(container)
        #expect(afterKeep[openID] == [earlier.id])
        #expect(afterKeep[namedID] == Set(members.map(\.id)))
        #expect(try trips(withID: openID, container).first?.customName == "Weekend")
    }

    @Test("a different trip back under the archived id blocks Keep as One Trip and is left as it is")
    func returnedOriginalIDBlocks() async throws {
        let split = try await makeSplit()
        let container = split.container
        let ctx = ModelContext(container)
        let lone = stay(ctx, Self.bedburg, 50.2, 50.8, .destination)
        let returned = trip(ctx, [lone])
        returned.id = split.tripID
        returned.customName = "Synced copy"
        try ctx.save()
        let before = try storeState(container)
        #expect(await split.classifier.keepSplitTripWhole(split.record, pinnedTripIDs: [])
                == .blocked(reasons: ["Synced copy"]))
        #expect(try storeState(container) == before)
    }

    @Test("a Keep whose save fails changes nothing, its carry log included, and keeps the archive, and a retry keeps the trip and logs its piece as carried onto it")
    func failedKeepSaveChangesNothing() async throws {
        let split = try await makeSplit()
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let earlier = "\(UUID().uuidString) \(UUID().uuidString)"
        defaults.set([earlier], forKey: TripDeduplicator.carriedFavouritesKey)
        let pieceID = try pieceHolding(split.ieper, split.container).id
        let before = try storeState(split.container)
        await split.classifier.failNextDissolvedRestoreSave()
        #expect(await split.classifier.keepSplitTripWhole(
            split.record, pinnedTripIDs: [], defaults: UserDefaults(suiteName: suite)!) == .saveFailed)
        #expect(try storeState(split.container) == before)
        #expect(defaults.stringArray(forKey: TripDeduplicator.carriedFavouritesKey) == [earlier])
        #expect(await split.classifier.keepSplitTripWhole(
            split.record, pinnedTripIDs: [], defaults: UserDefaults(suiteName: suite)!) == .kept)
        #expect(try trips(withID: split.tripID, split.container).count == 1)
        #expect(defaults.stringArray(forKey: TripDeduplicator.carriedFavouritesKey)
                == [earlier, "\(pieceID.uuidString) \(split.tripID.uuidString)"])
    }

    @Test("Keep as One Trip from the views pins the favourite again and removes the archive only once it committed; a blocked Keep keeps both as they are")
    func keepWrapperFinishesAfterTheCommit() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let split = try await makeSplit()
        try enqueue(split.record, in: directory)
        let pins = PinnedTripsStorage(forTesting: defaults)
        #expect(split.record.wasFavourite == true)

        // Renamed piece: blocked, the record stays and nothing is pinned.
        let ctx = ModelContext(split.container)
        let pieceID = try pieceHolding(split.ieper, split.container).id
        let piece = try #require(try ctx.fetch(FetchDescriptor<Trip>(
            predicate: #Predicate { $0.id == pieceID })).first)
        piece.customName = "Ieper day"
        try ctx.save()
        let blocked = await HomeAreaHealing.keepSplitTrip(
            split.record, classifier: split.classifier, gate: PipelineGate(forTesting: ()),
            pins: pins, queueDirectory: directory)
        #expect(blocked == .blocked(reasons: ["Ieper day"]))
        #expect(DissolvedTripQueue.load(from: directory).map(\.id) == [split.tripID])
        #expect(!pins.isPinned(split.tripID))

        piece.customName = nil
        try ctx.save()
        let kept = await StayClassificationInference.TestHook.$availability.withValue(false) {
            await HomeAreaHealing.keepSplitTrip(
                split.record, classifier: split.classifier, gate: PipelineGate(forTesting: ()),
                pins: pins, queueDirectory: directory)
        }
        #expect(kept == .kept)
        #expect(pins.isPinned(split.tripID))
        #expect(DissolvedTripQueue.load(from: directory).isEmpty)
        #expect(try membership(split.container)[split.tripID] == Set(split.record.stays.map(\.id)))
    }

    @Test("a Keep as One Trip that committed but whose archive was never removed is only finished by a retry: the favourite and the photo choice the user changed since stay as the user left them")
    func keepRetryKeepsLaterChoices() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let split = try await makeSplit()
        try enqueue(split.record, in: directory)
        let pins = PinnedTripsStorage(forTesting: defaults)
        let gate = PipelineGate(forTesting: ())

        // The gated Keep commits; the removal that should follow never happens.
        let first = await split.classifier.keepSplitTripWhole(
            split.record, pinnedTripIDs: { pins.pinnedIDs }, gate: gate,
            queueDirectory: directory, pin: { pins.pin($0) })
        #expect(first == .kept)
        #expect(pins.isPinned(split.tripID))
        #expect(try DissolvedTripQueue.record(id: split.tripID, in: directory)?.keepCommitted == true)
        let ctx = ModelContext(split.container)
        #expect(try ctx.fetch(FetchDescriptor<HiddenPhoto>()).map(\.tripID) == [split.tripID])

        // The user unfavourites the trip and shows the photo it hid.
        pins.unpin(split.tripID)
        for row in try ctx.fetch(FetchDescriptor<HiddenPhoto>()) { ctx.delete(row) }
        try ctx.save()

        let retried = await StayClassificationInference.TestHook.$availability.withValue(false) {
            await HomeAreaHealing.keepSplitTrip(
                split.record, classifier: split.classifier, gate: gate, pins: pins,
                queueDirectory: directory)
        }
        #expect(retried == .kept)
        #expect(!pins.isPinned(split.tripID))
        #expect(try ModelContext(split.container).fetch(FetchDescriptor<HiddenPhoto>()).isEmpty)
        #expect(DissolvedTripQueue.load(from: directory).isEmpty)
        #expect(try membership(split.container)[split.tripID] == Set(split.record.stays.map(\.id)))
    }

    @Test("a Keep as One Trip that runs as soon as the split's gate lets go, before the split's wrapper finishes, keeps the favourite it pins again: the split unpins its trips before it lets go")
    func keepRightAfterTheSplitStaysPinned() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let (row, original) = try seedSemesterTrip(container)
        let classifier = await makeClassifier(container)
        await classifier.setDissolvedRecordSink {
            try DissolvedTripQueue.append($0, in: directory)
        }
        let pins = PinnedTripsStorage(forTesting: defaults)
        pins.pin(original)
        let gate = PipelineGate(forTesting: ())
        let log = KeepLog()

        let outcome = await TripClassifier.TemporaryHomeTestHook.$afterUnit.withValue({
            guard let record = DissolvedTripQueue.load(from: directory).first else { return }
            let kept = await classifier.keepSplitTripWhole(
                record, pinnedTripIDs: { pins.pinnedIDs }, gate: gate,
                queueDirectory: directory, pin: { pins.pin($0) })
            await MainActor.run { log.outcome = kept }
        }) {
            await StayClassificationInference.TestHook.$availability.withValue(false) {
                await classifier.applyTemporaryHomeChange(
                    temporaryHomeID: row, pinnedTripIDs: { pins.pinnedIDs }, gate: gate,
                    unpinRetired: { ids in for id in ids { pins.unpin(id) } })
            }
        }
        #expect(outcome.isSettled)
        #expect(log.outcome == .kept)
        #expect(pins.isPinned(original))
        #expect(try trips(withID: original, container).count == 1)
    }

    // MARK: - The gated wrapper

    @Test("after the unit commits, its wrapper unpins the trips it split, once, and splits them as the core does")
    func wrapperUnpinsRetiredTrips() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let (row, original) = try seedSemesterTrip(container)
        let classifier = await makeClassifier(container)
        await classifier.setDissolvedRecordSink { _ in }
        let log = UnpinLog()
        let outcome = await StayClassificationInference.TestHook.$availability.withValue(false) {
            await classifier.applyTemporaryHomeChange(
                temporaryHomeID: row, pinnedTripIDs: { [original] },
                gate: PipelineGate(forTesting: ()),
                unpinRetired: { log.ids.append($0) })
        }
        #expect(outcome.isSettled)
        #expect(log.ids == [[original]])
        #expect(try trips(withID: original, container).isEmpty)
    }

    // MARK: - Preview

    /// Athens is the real Home. A Brussels holiday `holidayDaysAgo` days
    /// before `now`, back home, then the semester from 21 days ago as an open trip.
    private func seedHolidayThenSemester(
        _ container: ModelContainer, now: Date, holidayDaysAgo: Double
    ) throws -> Date {
        let ctx = ModelContext(container)
        func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
        func at(_ place: Place, from: Double, to: Double, _ category: StayCategory) -> Stay {
            let stay = Stay(
                startTime: ago(from), endTime: ago(to),
                centroidLatitude: place.lat, centroidLongitude: place.lon,
                h3IndexRes6: "S", pingCount: 6, distanceFromHomeKm: 0, pingIDs: [],
                timeZoneIdentifier: "Europe/Brussels")
            stay.category = category
            ctx.insert(stay)
            return stay
        }
        ctx.insert(Home(label: "Athens", latitude: Self.athens.lat, longitude: Self.athens.lon,
                        radiusKm: 25, startedAt: ago(2000)))
        _ = at(Self.athens, from: holidayDaysAgo + 20, to: holidayDaysAgo + 1, .home)
        let h1 = at(Self.brussels, from: holidayDaysAgo, to: holidayDaysAgo - 1.5, .destination)
        let h2 = at(Self.ieper, from: holidayDaysAgo - 1.7, to: holidayDaysAgo - 2.3, .destination)
        let h3 = at(Self.brussels, from: holidayDaysAgo - 2.5, to: holidayDaysAgo - 3.5, .destination)
        trip(ctx, [h1, h2, h3])
        _ = at(Self.athens, from: holidayDaysAgo - 4, to: 40, .home)
        _ = at(Self.athens, from: 39.5, to: 22, .home)
        let s1 = at(Self.brussels, from: 21, to: 12, .destination)
        let s2 = at(Self.brussels, from: 11.5, to: 0.2, .destination)
        trip(ctx, [s1, s2], complete: false)
        try ctx.save()
        return s1.startTime
    }

    @Test("the preview offers the arrival after the last stay at the real Home, not an earlier holiday in the same city, whatever the draft's dates",
          arguments: [60.0, 120.0])
    func arrivalSkipsAnEarlierHoliday(holidayDaysAgo: Double) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let now = date(9_000)
        let arrival = try seedHolidayThenSemester(container, now: now, holidayDaysAgo: holidayDaysAgo)
        let classifier = await makeClassifier(container)
        let draft = HomeAnchor(
            id: UUID(), kind: .temporary, label: "Erasmus",
            latitude: Self.brussels.lat, longitude: Self.brussels.lon, radiusKm: 25,
            locality: nil, isoCountryCode: nil, startedAt: now, endedAt: nil)
        let preview = try #require(await classifier.previewTemporaryHomeChange(
            draft: draft, removing: false, pinnedTripIDs: []))
        #expect(preview.arrivalInArea == arrival)
        #expect(preview.firstStayInArea == now.addingTimeInterval(-holidayDaysAgo * 86_400))
    }

    @Test("an area with no stay offers no arrival")
    func noStayNoArrival() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        try ctx.save()
        let classifier = await makeClassifier(container)
        let preview = try #require(await classifier.previewTemporaryHomeChange(
            draft: HomeAnchor(temporaryHome(ModelContext(container))), removing: false,
            pinnedTripIDs: []))
        #expect(preview.arrivalInArea == nil)
    }

    // MARK: - C2

    private struct C2Fixture {
        let semesterID: UUID
        let aID: UUID
        let bID: UUID
        let ieperIDs: Set<UUID>
        let bedburgID: UUID
    }

    /// Trip A (village, then Ieper x4), the base's stamped Brussels
    /// boundary, trip B (Bedburg x1), the real home closing it. The temporary
    /// home covers Brussels, days 10 to 100.
    private func seedC2(_ container: ModelContainer, withB: Bool = true) throws -> C2Fixture {
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0, 0.8, .home)
        let semester = temporaryHome(ctx, until: 100)
        let village = stay(ctx, Self.village, 10, 10.8, .destination)
        let ieper = [11.0, 12, 13, 14].map { stay(ctx, Self.ieper, $0, $0 + 0.8, .destination) }
        let tripA = trip(ctx, [village] + ieper)
        stay(ctx, Self.brussels, 15, 15.8, .home, by: semester.id)
        let bedburg = stay(ctx, Self.bedburg, 16, 16.8, .destination)
        let tripB = trip(ctx, [bedburg])
        stay(ctx, Self.athens, 18, 18.8, .home)
        if !withB {
            ctx.delete(tripB)
            ctx.delete(bedburg)
        }
        try ctx.save()
        return C2Fixture(semesterID: semester.id, aID: tripA.id, bID: tripB.id,
                         ieperIDs: Set(ieper.map(\.id)), bedburgID: bedburg.id)
    }

    /// The pin moves to the village, dates unchanged, as the edit form saves it.
    private func movePinToVillage(_ id: UUID, _ container: ModelContainer) throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let moved = TemporaryHomeSaveWorker.apply(
            TemporaryHomeSavePayload(
                target: .edit(id), label: "Semester",
                latitude: Self.village.lat, longitude: Self.village.lon,
                locality: "Village", administrativeArea: nil, country: "Greece",
                isoCountryCode: "GR", startedAt: date(10), endedAt: date(100),
                timeZoneIdentifier: "GMT", now: date(120)),
            context: ModelContext(container), pendingDefaults: defaults)
        #expect(moved.pendingReconciliation?.id == id)
    }

    @Test("a pin move that merges trip A's four surviving Ieper stays with trip B's one Bedburg stay gives the rebuilt trip A's id, the constituent with the most surviving stays, and parks nothing")
    func pinMoveMergeKeepsDominantIdentity() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let fixture = try seedC2(container)
        try movePinToVillage(fixture.semesterID, container)
        let classifier = await makeClassifier(container)
        let box = SplitRecordBox()
        await classifier.setDissolvedRecordSink { try box.append($0) }
        #expect(await reconcile(classifier, fixture.semesterID)
                == .committed(stamped: 1, freed: 1, rebuiltTrips: 1, protectedTrips: 0))
        #expect(try membership(container) == [fixture.aID: fixture.ieperIDs.union([fixture.bedburgID])])
        #expect(box.records.isEmpty)
    }

    @Test("with no trip B to merge, the same pin move gives the rebuilt Ieper trip A's id")
    func pinMoveWithoutMergeKeepsIdentity() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let fixture = try seedC2(container, withB: false)
        try movePinToVillage(fixture.semesterID, container)
        let classifier = await makeClassifier(container)
        let box = SplitRecordBox()
        await classifier.setDissolvedRecordSink { try box.append($0) }
        #expect(await reconcile(classifier, fixture.semesterID).isSettled)
        #expect(try membership(container) == [fixture.aID: fixture.ieperIDs])
        #expect(box.records.isEmpty)
    }

    @Test("after the follow-up pass the trip holding A's four Ieper stays still carries A's id")
    func gatedPinMoveKeepsDominantIdentity() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let fixture = try seedC2(container)
        try movePinToVillage(fixture.semesterID, container)
        let classifier = await makeClassifier(container)
        await classifier.setDissolvedRecordSink { _ in }
        let outcome = await StayClassificationInference.TestHook.$availability.withValue(false) {
            await classifier.applyTemporaryHomeChange(
                temporaryHomeID: fixture.semesterID, pinnedTripIDs: { [] },
                gate: PipelineGate(forTesting: ()), unpinRetired: { _ in })
        }
        #expect(outcome.isSettled)
        let holder = try #require(try membership(container).first { !$0.value.isDisjoint(with: fixture.ieperIDs) })
        #expect(fixture.ieperIDs.isSubset(of: holder.value))
        #expect(holder.key == fixture.aID)
    }
}
}
