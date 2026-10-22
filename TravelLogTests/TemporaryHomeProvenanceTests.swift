//
//  TemporaryHomeProvenanceTests.swift
//  TravelLogTests
//
//  Who made a stay home. A home stay records the temporary home whose ring
//  stamped it when no real Home's ring claimed it (`Stay.temporaryHomeID`),
//  in the same mutation as its category, and a temporary-home reconciliation
//  frees or hands on only the stays that record a temporary home it acts for.
//  These drive the ordinary pass, This Wasn't a Trip and
//  `applyTemporaryHomeChangeCore` on throwaway stores with primed shapes, the
//  model lane pinned off.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

private struct ProvenanceInjectedError: Error {}

@MainActor
@Suite("Temporary home provenance", IsolatedTitleDefaults())
struct TemporaryHomeProvenanceTests {

    private typealias Place = (lat: Double, lon: Double)
    private static let athens: Place = (38.0, 23.8)
    private static let brussels: Place = (50.8911, 4.3161)
    /// About 13 km north of the real home's pin: outside its measured area (the
    /// 10 km square), inside its declared 25 km circle. No city boundary.
    private static let village: Place = (38.113, 23.778)
    /// About 260 m east of the village: a second 1 km area over the first.
    private static let villageEast: Place = (38.113, 23.781)
    /// About 50 km north of Brussels.
    private static let outing: Place = (51.3411, 4.3158)
    /// Outside the Brussels urban centre.
    private static let airport: Place = (50.90, 4.48)
    /// About 16 km east of the real home's pin.
    private static let nearAthens: Place = (38.0, 23.99)

    private typealias Outcome = TripClassifier.TemporaryHomeReconciliationOutcome
    private static let nothing = Outcome.committed(
        stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 0)

    /// Fixture day 0 is 217 days before the shared fixture's day 0.
    private func date(_ day: Double) -> Date { TemporaryHomeFixture.date(day - 217) }

    @discardableResult
    private func stay(
        _ ctx: ModelContext, _ place: Place, day: Double, days: Double = 0.8,
        _ category: StayCategory = .unclassified, source: DataSource = .liveSLC
    ) -> Stay {
        let start = date(day)
        return TemporaryHomeFixture.stay(
            ctx, place, from: start, to: start.addingTimeInterval(days * 86_400), category,
            hex: "P", pingCount: 2, source: source, zone: "GMT")
    }

    @discardableResult
    private func trip(_ ctx: ModelContext, _ stays: [Stay]) -> Trip {
        TemporaryHomeFixture.trip(ctx, stays, complete: true)
    }

    /// The real home in Athens since long before the fixture, with a home stay on day 0.
    @discardableResult
    private func seedAthens(_ ctx: ModelContext) -> Home {
        let home = TemporaryHomeFixture.realHome(ctx, "Athens", at: Self.athens)
        home.startedAt = date(-1000)
        stay(ctx, Self.athens, day: 0, .home)
        return home
    }

    @discardableResult
    private func temporaryHome(
        _ ctx: ModelContext, at place: Place, from: Double, until: Double? = 100
    ) -> TemporaryHome {
        TemporaryHomeFixture.temporaryHome(
            ctx, "Semester", at: place,
            from: from - 217, until: until.map { $0 - 217 }, zone: "GMT")
    }

    private func makeClassifier(_ container: ModelContainer) async -> TripClassifier {
        await TemporaryHomeFixture.classifier(
            container, squares: [(1, Self.athens), (2, Self.brussels)],
            discs: [Self.village, Self.villageEast])
    }

    private func reconcile(_ classifier: TripClassifier, _ id: UUID) async -> Outcome {
        await classifier.applyTemporaryHomeChangeCore(temporaryHomeID: id, pinnedTripIDs: [])
    }

    /// One ordinary pipeline pass.
    private func ordinaryPass(_ classifier: TripClassifier) async {
        await TemporaryHomeFixture.ordinaryPass(classifier)
    }

    /// Writes every row with the id as an edit or End saves it.
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

    /// Remove Temporary Home as the save worker writes it: every row with the
    /// id keeps its content and carries the removal.
    private func markRemoved(_ id: UUID, _ container: ModelContainer) throws {
        try editRows(id, container) { $0.removedAt = date(120) }
    }

    /// Every physical row with the id, as committed.
    private func rows(_ id: UUID, _ container: ModelContainer) throws -> [Stay] {
        try ModelContext(container).fetch(FetchDescriptor<Stay>(
            predicate: #Predicate { $0.id == id }))
    }

    private func stored(_ id: UUID, _ container: ModelContainer) throws -> Stay {
        let found = try rows(id, container)
        try #require(found.count == 1)
        return found[0]
    }

    private func corrections(_ container: ModelContainer) throws -> [HomeAreaOverride] {
        try ModelContext(container).fetch(FetchDescriptor<HomeAreaOverride>())
    }

    // MARK: - Writers

    @Test("the ordinary pass's pre-filter records the temporary home that made a stay home, and nothing for a stay a real home's ring also claims or one it leaves out of home")
    func preFilterRecordsTheTemporaryOwner() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let semester = temporaryHome(ctx, at: Self.brussels, from: 10)
        // A stretch at home declared as a temporary home too: the real home claims it.
        temporaryHome(ctx, at: Self.athens, from: 40)
        let during = stay(ctx, Self.brussels, day: 20)
        let atHome = stay(ctx, Self.athens, day: 50)
        let before = stay(ctx, Self.brussels, day: 5)
        stay(ctx, Self.athens, day: 7, .home)
        try ctx.save()

        await ordinaryPass(await makeClassifier(container))
        let stamped = try stored(during.id, container)
        #expect(stamped.category == .home)
        #expect(stamped.temporaryHomeID == semester.id)
        let real = try stored(atHome.id, container)
        #expect(real.category == .home)
        #expect(real.temporaryHomeID == nil)
        let earlier = try stored(before.id, container)
        #expect(earlier.category != .home)
        #expect(earlier.temporaryHomeID == nil)
    }

    @Test("when two temporary homes claim a stay, the one first in canonical order is recorded: the earlier start, then the smaller id")
    func preFilterRecordsTheFirstTemporaryOwner() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let later = temporaryHome(ctx, at: Self.brussels, from: 10)
        let earlier = temporaryHome(ctx, at: Self.brussels, from: 8)
        let tiedLow = temporaryHome(ctx, at: Self.village, from: 10)
        let tiedHigh = temporaryHome(ctx, at: Self.villageEast, from: 10)
        tiedLow.id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        tiedHigh.id = try #require(UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001"))
        let atTheBase = stay(ctx, Self.brussels, day: 20)
        let atTheVillage = stay(ctx, Self.villageEast, day: 30)
        try ctx.save()

        await ordinaryPass(await makeClassifier(container))
        #expect(try stored(atTheBase.id, container).temporaryHomeID == earlier.id)
        #expect(try stored(atTheVillage.id, container).temporaryHomeID == tiedLow.id)
        // The rule itself, with the rings in either order of the same canonical list.
        let rings = [later, earlier].map { TripClassifier.HomeRing(HomeAnchor($0)) }
        let canonical = TripClassifier.canonicalAnchorOrder(
            [HomeAnchor(later), HomeAnchor(earlier)]).map { TripClassifier.HomeRing($0) }
        #expect(canonical.map(\.homeID) == [earlier.id, later.id])
        #expect(TripClassifier.temporaryOwner(
            stayStart: date(20), latitude: Self.brussels.lat, longitude: Self.brussels.lon,
            rings: rings) == later.id)
        #expect(TripClassifier.temporaryOwner(
            stayStart: date(20), latitude: Self.brussels.lat, longitude: Self.brussels.lon,
            rings: canonical) == earlier.id)
    }

    @Test("with no temporary home in the store, the pre-filter and a full ordinary pass leave every stay recording none")
    func noTemporaryHomeRecordsNothing() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let atHome = stay(ctx, Self.athens, day: 1)
        // Before the real home's record: the prehistory pass claims it.
        let prehistory = stay(ctx, Self.athens, day: -2000)
        stay(ctx, Self.brussels, day: 3, days: 2)
        stay(ctx, Self.athens, day: 6, .unclassified)
        try ctx.save()

        let classifier = await makeClassifier(container)
        #expect(await classifier.preFilterStays() == 3)
        await ordinaryPass(classifier)
        #expect(try stored(atHome.id, container).category == .home)
        #expect(try stored(prehistory.id, container).category == .home)
        let all = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        #expect(all.count == 5)
        #expect(all.allSatisfy { $0.temporaryHomeID == nil })
    }

    @Test("This Wasn't a Trip records, for every member it makes home, the temporary home whose correction claims it, the airport included, and nothing near the real home; Undo leaves none")
    func demotionRecordsTheOwnerPerMember() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let semester = temporaryHome(ctx, at: Self.brussels, from: 10)
        let semesterID = semester.id
        let nearHome = stay(ctx, Self.nearAthens, day: 8, .destination)
        let homeTrip = trip(ctx, [nearHome])
        let day = stay(ctx, Self.outing, day: 13, .destination)
        let flight = stay(ctx, Self.airport, day: 13.85, days: 0.05, .transit)
        flight.isAirport = true
        let baseTrip = trip(ctx, [day, flight])
        try ctx.save()
        let classifier = await makeClassifier(container)

        #expect(await classifier.demoteTripToHomeArea(
            tripID: homeTrip.id, tripIdentifier: homeTrip.persistentModelID)
            == .demoted(tripName: homeTrip.displayName))
        #expect(try stored(nearHome.id, container).category == .home)
        #expect(try stored(nearHome.id, container).temporaryHomeID == nil)

        #expect(await classifier.demoteTripToHomeArea(
            tripID: baseTrip.id, tripIdentifier: baseTrip.persistentModelID)
            == .demoted(tripName: baseTrip.displayName))
        for member in [day, flight] {
            let demoted = try stored(member.id, container)
            #expect(demoted.category == .home)
            #expect(demoted.userOverridden)
            #expect(demoted.temporaryHomeID == semesterID)
        }

        #expect(await classifier.undoLastDemotion() == .undone)
        #expect(try stored(day.id, container).category == .destination)
        #expect(try stored(flight.id, container).category == .transit)
        for member in [day, flight] {
            #expect(try stored(member.id, container).temporaryHomeID == nil)
        }
    }

    // Owners were keyed by stay id, so
    // the later cluster's temporary home overwrote the earlier one's.
    @Test("This Wasn't a Trip records each physical row's own temporary home when two rows share one stay id at two temporary homes, and removing one of them frees only its row")
    func demotionRecordsTheOwnerPerPhysicalRow() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let vienna: Place = (48.1764, 16.2938)
        let brusselsID = temporaryHome(ctx, at: Self.brussels, from: 10).id
        let viennaID = temporaryHome(ctx, at: vienna, from: 10).id
        let atBrussels = stay(ctx, Self.brussels, day: 20, .destination)
        let atVienna = stay(ctx, vienna, day: 20, .destination)
        atVienna.id = atBrussels.id
        let journey = trip(ctx, [atBrussels, atVienna])
        try ctx.save()
        let (brusselsRow, viennaRow) = (atBrussels.persistentModelID, atVienna.persistentModelID)
        func physical(_ row: PersistentIdentifier) throws -> Stay {
            try #require(try rows(atBrussels.id, container).first { $0.persistentModelID == row })
        }

        let classifier = await makeClassifier(container)
        await classifier.primeShapeForTesting(
            latitude: vienna.lat, longitude: vienna.lon,
            shape: TemporaryHomeFixture.squareShape(id: 3, around: vienna))
        #expect(await classifier.demoteTripToHomeArea(
            tripID: journey.id, tripIdentifier: journey.persistentModelID)
            == .demoted(tripName: journey.displayName))
        for (row, owner) in [(brusselsRow, brusselsID), (viennaRow, viennaID)] {
            let demoted = try physical(row)
            #expect(demoted.category == .home)
            #expect(demoted.userOverridden)
            #expect(demoted.temporaryHomeID == owner)
        }

        try markRemoved(viennaID, container)
        #expect(await reconcile(classifier, viennaID)
                == .committed(stamped: 0, freed: 1, rebuiltTrips: 0, protectedTrips: 0))
        let freed = try physical(viennaRow)
        #expect(freed.category == .unclassified)
        #expect(freed.temporaryHomeID == nil)
        #expect(!freed.userOverridden)
        let left = try physical(brusselsRow)
        #expect(left.category == .home)
        #expect(left.temporaryHomeID == brusselsID)
        #expect(try corrections(container).map(\.homeID) == [brusselsID])
    }

    // MARK: - What a unit may release

    @Test("a stay the ordinary pass made home while a pin move was still owed records the moved temporary home, so its removal frees it, while an older home stay at the same spot that records none stays home")
    func ordinaryPassProvenanceSurvivesAnOwedEdit() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let legacy = stay(ctx, Self.village, day: 2, .home)
        let id = temporaryHome(ctx, at: Self.brussels, from: 10).id
        try ctx.save()

        // The pin moves to the village; its reconciliation fails a required read.
        try editRows(id, container) { row in
            row.latitude = Self.village.lat
            row.longitude = Self.village.lon
        }
        let classifier = await makeClassifier(container)
        classifier.failReconciliationStayReadForTesting = true
        #expect(await classifier.applyTemporaryHomeChange(
            temporaryHomeID: id, pinnedTripIDs: { [] }, gate: PipelineGate(forTesting: ())) == .failed)
        classifier.failReconciliationStayReadForTesting = false

        // A live stay at the village arrives and the ordinary pass judges it.
        let live = ModelContext(container)
        let liveID = stay(live, Self.village, day: 20).id
        try live.save()
        await ordinaryPass(classifier)
        let stamped = try stored(liveID, container)
        #expect(stamped.category == .home)
        #expect(stamped.temporaryHomeID == id)

        // Removed before the owed reconciliation ever ran.
        try markRemoved(id, container)
        #expect(await reconcile(await makeClassifier(container), id)
                == .committed(stamped: 0, freed: 1, rebuiltTrips: 0, protectedTrips: 0))
        let freed = try stored(liveID, container)
        #expect(freed.category == .unclassified)
        #expect(freed.temporaryHomeID == nil)
        #expect(try stored(legacy.id, container).category == .home)
    }

    @Test("an ordinary pass whose save fails leaves the stay it stamped unclassified and recording nothing, its same-id twin at the real home keeps its own state, and a later removal frees neither")
    func rolledBackStampLeavesNoProvenance() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let legacy = stay(ctx, Self.village, day: 2, .home)
        let id = temporaryHome(ctx, at: Self.village, from: 10).id
        let live = stay(ctx, Self.village, day: 20)
        // A copy of the same stay id at the real home, home by the real ring.
        let twin = stay(ctx, Self.athens, day: 20, .home)
        twin.id = live.id
        try ctx.save()

        let classifier = await makeClassifier(container)
        await StayClassificationInference.TestHook.$availability.withValue(false) {
            _ = await classifier.classifyAndAssembleTripsReportingChangesWithGates(
                maxStaysPerCall: nil, gate: PipelineGate(forTesting: ()),
                beforeSave: { throw ProvenanceInjectedError() })
        }
        func copies() throws -> (village: Stay, athens: Stay) {
            let found = try rows(live.id, container)
            try #require(found.count == 2)
            let village = try #require(found.first { $0.centroidLatitude == Self.village.lat })
            let athens = try #require(found.first { $0.centroidLatitude == Self.athens.lat })
            return (village, athens)
        }
        var state = try copies()
        #expect(state.village.category == .unclassified)
        #expect(state.village.temporaryHomeID == nil)
        #expect(state.athens.category == .home)
        #expect(state.athens.temporaryHomeID == nil)

        try markRemoved(id, container)
        #expect(await reconcile(await makeClassifier(container), id) == Self.nothing)
        state = try copies()
        #expect(state.village.category == .unclassified)
        #expect(state.athens.category == .home)
        #expect(try stored(legacy.id, container).category == .home)
    }

    @Test("of two rows with one temporary home's id and different dates, only the stays the winning row made home are freed when both move their start")
    func temporaryHomeTwinsFreeOnlyWhatTheWinnerStamped() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let winner = temporaryHome(ctx, at: Self.brussels, from: 5)
        winner.modifiedAt = date(50)
        let loser = temporaryHome(ctx, at: Self.brussels, from: 1)
        loser.id = winner.id
        loser.modifiedAt = date(40)
        let id = winner.id
        let older = stay(ctx, Self.brussels, day: 2, .home)
        let beforeTheWinner = stay(ctx, Self.brussels, day: 3)
        let insideBoth = stay(ctx, Self.brussels, day: 7)
        try ctx.save()

        #expect(await reconcile(await makeClassifier(container), id)
                == .committed(stamped: 1, freed: 0, rebuiltTrips: 0, protectedTrips: 0))
        #expect(try stored(insideBoth.id, container).temporaryHomeID == id)
        #expect(try stored(beforeTheWinner.id, container).category == .unclassified)

        try editRows(id, container) { $0.startedAt = date(10) }
        #expect(await reconcile(await makeClassifier(container), id)
                == .committed(stamped: 0, freed: 1, rebuiltTrips: 0, protectedTrips: 0))
        #expect(try stored(insideBoth.id, container).category == .unclassified)
        #expect(try stored(beforeTheWinner.id, container).category == .unclassified)
        #expect(try stored(older.id, container).category == .home)
    }

    @Test("two temporary homes over one place, removed in either order: the stay they share stays home after the first removal, recording the one left, and is freed once, at the last",
          arguments: [true, false])
    func overlappingTemporaryHomesFreeTheSharedStayOnce(ownerFirst: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let a = temporaryHome(ctx, at: Self.brussels, from: 10).id
        let b = temporaryHome(ctx, at: Self.brussels, from: 10).id
        let shared = stay(ctx, Self.brussels, day: 20)
        try ctx.save()
        #expect(await reconcile(await makeClassifier(container), a)
                == .committed(stamped: 1, freed: 0, rebuiltTrips: 0, protectedTrips: 0))
        let owner = try #require(try stored(shared.id, container).temporaryHomeID)
        #expect([a, b].contains(owner))
        let other = owner == a ? b : a
        let (first, last) = ownerFirst ? (owner, other) : (other, owner)

        try markRemoved(first, container)
        #expect(await reconcile(await makeClassifier(container), first) == Self.nothing)
        let kept = try stored(shared.id, container)
        #expect(kept.category == .home)
        #expect(kept.temporaryHomeID == last)

        try markRemoved(last, container)
        #expect(await reconcile(await makeClassifier(container), last)
                == .committed(stamped: 0, freed: 1, rebuiltTrips: 0, protectedTrips: 0))
        #expect(try stored(shared.id, container).category == .unclassified)
        // A replay of either unit finds nothing more to free.
        for id in [first, last] {
            #expect(await reconcile(await makeClassifier(container), id) == Self.nothing)
        }
    }

    @Test("when the photo stays a temporary home made home are discarded, its removal still frees the live stay it made home")
    func photoDiscardCannotHideWhatTheTemporaryHomeMadeHome() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let id = temporaryHome(ctx, at: Self.brussels, from: 10).id
        for offset in 0..<16 {
            stay(ctx, Self.brussels, day: 20 + Double(offset), days: 0.5, source: .photoImport)
        }
        let live = stay(ctx, Self.brussels, day: 40)
        try ctx.save()
        #expect(await reconcile(await makeClassifier(container), id)
                == .committed(stamped: 17, freed: 0, rebuiltTrips: 0, protectedTrips: 0))

        // The discard deletes the photo stays.
        let discard = ModelContext(container)
        for photo in try discard.fetch(FetchDescriptor<Stay>())
        where photo.sourceRaw == DataSource.photoImport.rawValue {
            discard.delete(photo)
        }
        try discard.save()

        try markRemoved(id, container)
        #expect(await reconcile(await makeClassifier(container), id)
                == .committed(stamped: 0, freed: 1, rebuiltTrips: 0, protectedTrips: 0))
        #expect(try stored(live.id, container).category == .unclassified)
    }

    @Test("a reconciliation queued for a temporary home this device holds neither as a row nor as removed, as an interrupted import leaves it, frees no stay that records it and deletes no correction keyed to it")
    func interruptedDeclarationImportDoesNotImplyRemoval() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let missing = UUID()
        // A day demoted on another device, with its correction, synced ahead of the declaration.
        let demoted = stay(ctx, Self.outing, day: 30, .home)
        demoted.userOverridden = true
        demoted.temporaryHomeID = missing
        ctx.insert(HomeAreaOverride(
            kind: .include, centerLatitude: Self.outing.lat, centerLongitude: Self.outing.lon,
            radiusKm: 1, homeID: missing))
        try ctx.save()

        let classifier = await makeClassifier(container)
        #expect(await reconcile(classifier, missing) == Self.nothing)
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        let kept = try stored(demoted.id, container)
        #expect(kept.category == .home)
        #expect(kept.userOverridden)
        #expect(kept.temporaryHomeID == missing)
        #expect(try corrections(container).map(\.homeID) == [missing])
    }

    // MARK: - Handoff

    @Test("removing a temporary home hands a stay another one still claims to that one in the same unit that frees the rest, and the second removal frees it")
    func handoffToTheTemporaryHomeThatStillClaims() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let a = temporaryHome(ctx, at: Self.brussels, from: 10).id
        let b = temporaryHome(ctx, at: Self.brussels, from: 15).id
        let onlyA = stay(ctx, Self.brussels, day: 12)
        let both = stay(ctx, Self.brussels, day: 30)
        try ctx.save()
        #expect(await reconcile(await makeClassifier(container), a)
                == .committed(stamped: 2, freed: 0, rebuiltTrips: 0, protectedTrips: 0))
        #expect(try stored(both.id, container).temporaryHomeID == a)
        #expect(await reconcile(await makeClassifier(container), b) == Self.nothing)

        try markRemoved(a, container)
        #expect(await reconcile(await makeClassifier(container), a)
                == .committed(stamped: 0, freed: 1, rebuiltTrips: 0, protectedTrips: 0))
        #expect(try stored(onlyA.id, container).category == .unclassified)
        let handed = try stored(both.id, container)
        #expect(handed.category == .home)
        #expect(handed.temporaryHomeID == b)

        try markRemoved(b, container)
        #expect(await reconcile(await makeClassifier(container), b)
                == .committed(stamped: 0, freed: 1, rebuiltTrips: 0, protectedTrips: 0))
        #expect(try stored(both.id, container).category == .unclassified)
    }

    @Test("a day demoted to the nearer of two overlapping temporary homes keeps that home, its override and its correction when that home's end moves, although the other one comes first in canonical order")
    func handoffPreservesAStillClaimingManualOwner() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        temporaryHome(ctx, at: Self.village, from: 10)
        let nearer = temporaryHome(ctx, at: Self.villageEast, from: 15).id
        let day = stay(ctx, Self.villageEast, day: 30, .destination)
        let edited = trip(ctx, [day])
        edited.userEdited = true
        try ctx.save()
        let classifier = await makeClassifier(container)
        #expect(await classifier.demoteTripToHomeArea(
            tripID: edited.id, tripIdentifier: edited.persistentModelID)
            == .demoted(tripName: edited.displayName))
        #expect(try stored(day.id, container).temporaryHomeID == nearer)
        #expect(try corrections(container).map(\.homeID) == [nearer])

        try editRows(nearer, container) { $0.endedAt = date(101) }
        #expect(await reconcile(await makeClassifier(container), nearer) == Self.nothing)
        let kept = try stored(day.id, container)
        #expect(kept.category == .home)
        #expect(kept.userOverridden)
        #expect(kept.temporaryHomeID == nearer)
        #expect(try corrections(container).map(\.homeID) == [nearer])
    }

    @Test("a temporary home moved away hands its stay to another temporary home that still claims it although a real home's correction claims it too, saving the hand alone, so removing that one later frees the stay and leaves the older home stay at the spot")
    func realClaimDoesNotBlockRequiredTemporaryHandoff() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let athens = seedAthens(ctx)
        let legacy = stay(ctx, Self.village, day: 2, .home)
        let a = temporaryHome(ctx, at: Self.village, from: 10).id
        let shared = stay(ctx, Self.village, day: 30)
        try ctx.save()
        #expect(await reconcile(await makeClassifier(container), a)
                == .committed(stamped: 1, freed: 0, rebuiltTrips: 0, protectedTrips: 0))
        #expect(try stored(shared.id, container).temporaryHomeID == a)

        // A correction of the real home's at the spot syncs in; a second temporary home is added there.
        let later = ModelContext(container)
        let correction = HomeAreaOverride(
            kind: .include, centerLatitude: Self.village.lat, centerLongitude: Self.village.lon,
            radiusKm: 1, homeID: athens.id)
        later.insert(correction)
        let b = temporaryHome(later, at: Self.village, from: 15).id
        try later.save()
        let correctionID = correction.id
        #expect(await reconcile(await makeClassifier(container), b) == Self.nothing)

        // The first one's pin moves to Brussels. Nothing moves; the hand is saved.
        try editRows(a, container) { row in
            row.latitude = Self.brussels.lat
            row.longitude = Self.brussels.lon
        }
        let classifier = await makeClassifier(container)
        await classifier.failNextReconciliationSaveForTesting()
        #expect(await reconcile(classifier, a) == .failed)
        #expect(try stored(shared.id, container).temporaryHomeID == a)
        #expect(await reconcile(classifier, a) == Self.nothing)
        #expect(try stored(shared.id, container).temporaryHomeID == b)

        // The real home's correction is withdrawn, then the second temporary home removed.
        let withdrawal = ModelContext(container)
        for row in try withdrawal.fetch(FetchDescriptor<HomeAreaOverride>()) where row.id == correctionID {
            withdrawal.delete(row)
        }
        try withdrawal.save()
        try markRemoved(b, container)
        #expect(await reconcile(await makeClassifier(container), b)
                == .committed(stamped: 0, freed: 1, rebuiltTrips: 0, protectedTrips: 0))
        #expect(try stored(shared.id, container).category == .unclassified)
        #expect(try stored(legacy.id, container).category == .home)
    }

    // MARK: - Preview

    /// The change the sheet previews and then saves.
    enum Change: String, CaseIterable, Sendable {
        case edit, end, remove
    }

    @Test("with two overlapping temporary homes, the preview of an edit, an end and a removal counts the stays its unit then frees",
          arguments: Change.allCases)
    func previewAndUnitAgreeWithOverlappingTemporaryHomes(change: Change) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let a = temporaryHome(ctx, at: Self.brussels, from: 10).id
        let days = [20.0, 40, 60, 80].map { stay(ctx, Self.brussels, day: $0).id }
        try ctx.save()
        #expect(await reconcile(await makeClassifier(container), a)
                == .committed(stamped: 4, freed: 0, rebuiltTrips: 0, protectedTrips: 0))
        let second = ModelContext(container)
        let b = temporaryHome(second, at: Self.brussels, from: 50).id
        try second.save()
        #expect(await reconcile(await makeClassifier(container), b) == Self.nothing)

        let anchor = try #require(try HomeAnchors.temporaryHomes(in: ModelContext(container))
            .first { $0.id == a })
        func draft(from: Double, until: Double) -> HomeAnchor {
            HomeAnchor(
                id: a, kind: .temporary, label: anchor.label,
                latitude: anchor.latitude, longitude: anchor.longitude, radiusKm: anchor.radiusKm,
                locality: nil, isoCountryCode: nil, startedAt: date(from), endedAt: date(until))
        }
        let expected: Int
        let preview: TripClassifier.TemporaryHomeChangePreview?
        switch change {
        case .edit:
            // Days 20 and 40 leave; 60 and 80 are still the first one's.
            expected = 2
            preview = await makeClassifier(container).previewTemporaryHomeChange(
                draft: draft(from: 45, until: 100), removing: false, pinnedTripIDs: [])
            try editRows(a, container) { $0.startedAt = date(45) }
        case .end:
            // Day 40 leaves; 60 and 80 pass to the second one.
            expected = 1
            preview = await makeClassifier(container).previewTemporaryHomeChange(
                draft: draft(from: 10, until: 30), removing: false, pinnedTripIDs: [])
            try editRows(a, container) { $0.endedAt = date(30) }
        case .remove:
            // Days 20 and 40 leave; 60 and 80 pass to the second one.
            expected = 2
            preview = await makeClassifier(container).previewTemporaryHomeChange(
                draft: anchor, removing: true, pinnedTripIDs: [])
            try markRemoved(a, container)
        }
        let shown = try #require(preview)
        #expect(shown.staysLeaving == expected)
        #expect(shown.staysJoining == 0)
        #expect(await reconcile(await makeClassifier(container), a)
                == .committed(stamped: 0, freed: shown.staysLeaving, rebuiltTrips: 0,
                              protectedTrips: 0))
        for id in days.suffix(2) {
            let kept = try stored(id, container)
            #expect(kept.category == .home)
            #expect(kept.temporaryHomeID == (change == .edit ? a : b))
        }
    }
}

extension TemporaryHomeProvenanceTests {
    @Test("what a stay records is who it belongs to where it is shown: nothing means the real Home, a known id (live or removed) that temporary home, an id this store does not hold nobody yet")
    func recordedOwnerReadsTheStamp() {
        let live = UUID()
        let removed = UUID()
        let known: Set<UUID> = [live, removed]
        #expect(HomeAnchors.recordedOwner(temporaryHomeID: nil, knownTemporaryHomeIDs: known) == .realHome)
        #expect(HomeAnchors.recordedOwner(temporaryHomeID: live, knownTemporaryHomeIDs: known) == .temporary(live))
        #expect(HomeAnchors.recordedOwner(temporaryHomeID: removed, knownTemporaryHomeIDs: known) == .temporary(removed))
        #expect(HomeAnchors.recordedOwner(temporaryHomeID: UUID(), knownTemporaryHomeIDs: known) == .unresolved)
        #expect(HomeAnchors.recordedOwner(temporaryHomeID: nil, knownTemporaryHomeIDs: []) == .realHome)
    }
}
