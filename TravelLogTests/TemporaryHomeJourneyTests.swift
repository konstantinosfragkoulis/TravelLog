//
//  TemporaryHomeJourneyTests.swift
//  TravelLogTests
//
//  One test per user journey with a temporary home, on a small hand-built
//  store: the real reconciliation unit (`applyTemporaryHomeChangeCore`), the
//  real ordinary pipeline pass (pre-filter, heuristics with Foundation Models
//  pinned off, assembly, closure) and the real away ledger. Each asserts what
//  the user ends up seeing: categories, trip membership, ids, dates, days.
//  The long replays of the same journeys are in `TemporaryHomeScenarioTests`.
//
//  Fixture time is whole days from midnight UTC on 9 October 2000, and every
//  stay carries the GMT zone, so "day 13" is one civil date everywhere.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Temporary home journeys", IsolatedTitleDefaults())
struct TemporaryHomeJourneyTests {

    private typealias Place = (lat: Double, lon: Double)
    private static let athens: Place = (38.0, 23.8)
    private static let brussels: Place = (50.85, 4.35)
    /// About 111 km north of Brussels.
    private static let ieper: Place = (51.85, 4.35)
    /// About 140 km east of Brussels.
    private static let bedburg: Place = (50.85, 6.35)
    /// Outside the Brussels urban centre.
    private static let airport: Place = (50.90, 4.48)
    private static let vienna: Place = (48.21, 16.37)
    /// About 111 km north of Vienna.
    private static let brno: Place = (49.21, 16.37)

    /// Fixture day 0 sits 12 weeks before the shared fixture's day 0.
    private static let dayZero: Double = -84

    private func date(_ day: Double) -> Date { TemporaryHomeFixture.date(day + Self.dayZero) }

    /// The `TravelDays` labels of whole fixture days.
    private func labels(_ days: [ClosedRange<Int>]) -> Set<Date> {
        Set(days.flatMap { $0 }.map { date(Double($0)) })
    }

    /// A live stay from fixture day `from` to `to`. Unclassified is how the
    /// clusterer writes one; a category is how an earlier pass left it.
    /// `by` is the temporary home a home stay records as having made it home.
    @discardableResult
    private func stay(
        _ ctx: ModelContext, _ place: Place, _ from: Double, _ to: Double,
        _ category: StayCategory = .unclassified, airport: Bool = false, fixes: Int = 2,
        by temporaryHomeID: UUID? = nil
    ) -> Stay {
        TemporaryHomeFixture.stay(
            ctx, place, from: date(from), to: date(to), category, hex: "J", pingCount: fixes,
            zone: "GMT", airport: airport, idOnlyStamp: temporaryHomeID)
    }

    @discardableResult
    private func trip(_ ctx: ModelContext, _ stays: [Stay]) -> Trip {
        TemporaryHomeFixture.trip(ctx, stays, complete: true)
    }

    /// The real home in Athens since long before the fixture.
    private func seedAthens(_ ctx: ModelContext) {
        let home = TemporaryHomeFixture.realHome(ctx, "Athens", at: Self.athens)
        home.startedAt = date(-1000)
    }

    private func temporaryHome(
        _ ctx: ModelContext, _ label: String = "Brussels", at chosen: Place? = nil,
        from: Double, until: Double?
    ) -> TemporaryHome {
        TemporaryHomeFixture.temporaryHome(
            ctx, label, at: chosen ?? Self.brussels, from: from + Self.dayZero,
            until: until.map { $0 + Self.dayZero }, zone: nil)
    }

    /// Remove Temporary Home as the save worker writes it: the row keeps its
    /// content and carries the removal.
    private func markRemoved(_ row: TemporaryHome, _ ctx: ModelContext, on day: Double) throws {
        row.removedAt = date(day)
        row.modifiedAt = date(day)
        try ctx.save()
    }

    private func makeClassifier(_ container: ModelContainer) async -> TripClassifier {
        await TemporaryHomeFixture.classifier(
            container, squares: [(1, Self.athens), (2, Self.brussels), (3, Self.vienna)])
    }

    /// What Settings runs after a temporary-home save, without its title stage.
    private func reconcile(
        _ classifier: TripClassifier, _ id: UUID, pinned: Set<UUID> = []
    ) async -> TripClassifier.TemporaryHomeReconciliationOutcome {
        await classifier.applyTemporaryHomeChangeCore(temporaryHomeID: id, pinnedTripIDs: pinned)
    }

    private func ordinaryPass(_ classifier: TripClassifier) async {
        await TemporaryHomeFixture.ordinaryPass(classifier)
    }

    // MARK: Reading the store

    private struct TripFacts: Equatable {
        let id: UUID
        let stays: Set<UUID>
        let start: Date
        let end: Date?
        let isComplete: Bool
        let days: Int?
    }

    /// Every trip as committed, in start order.
    private func trips(_ container: ModelContainer) throws -> [TripFacts] {
        try ModelContext(container).fetch(FetchDescriptor<Trip>())
            .sorted { $0.startDate < $1.startDate }
            .map {
                TripFacts(id: $0.id, stays: Set(($0.stays ?? []).map(\.id)), start: $0.startDate,
                          end: $0.endDate, isComplete: $0.isComplete, days: $0.durationDays)
            }
    }

    /// Category and trip id of each stay, as committed.
    private func state(_ container: ModelContainer) throws -> [UUID: String] {
        var result: [UUID: String] = [:]
        for stay in try ModelContext(container).fetch(FetchDescriptor<Stay>()) {
            result[stay.id] = stay.categoryRaw + (stay.trip.map { " in \($0.id)" } ?? "")
        }
        return result
    }

    private func expect(
        _ stays: [Stay], are category: StayCategory, in tripID: UUID?, _ container: ModelContainer,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let now = try state(container)
        let wanted = category.rawValue + (tripID.map { " in \($0)" } ?? "")
        for stay in stays {
            #expect(now[stay.id] == wanted, sourceLocation: sourceLocation)
        }
    }

    // MARK: - 1

    @Test("declared on arrival, one side trip and back: the stays at the base are home and tripless, the side trip is one completed trip of its own days, and the flight in is no trip")
    func declaredOnArrivalSideTripAndBack() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        let semester = temporaryHome(ctx, from: 10, until: nil)
        try ctx.save()
        let classifier = await makeClassifier(container)
        #expect(await reconcile(classifier, semester.id)
                == .committed(stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 0))

        // The semester, as the clusterer writes it.
        let flight = stay(ctx, (37.94, 23.95), 9.5, 9.6, airport: true)
        let first = stay(ctx, Self.brussels, 10.2, 12.8)
        let side = stay(ctx, Self.ieper, 13.2, 13.8)
        let second = stay(ctx, Self.brussels, 14.2, 20.8)
        try ctx.save()
        await ordinaryPass(classifier)

        try expect([first, second], are: .home, in: nil, container)
        try expect([flight], are: .transit, in: nil, container)
        let all = try trips(container)
        try #require(all.count == 1)
        #expect(all[0].stays == [side.id])
        #expect(all[0].start == date(13.2))
        #expect(all[0].end == date(13.8))
        #expect(all[0].isComplete)
        #expect(all[0].days == 1)
        try expect([side], are: .destination, in: all[0].id, container)
    }

    // MARK: - 2 (both readings of the visit home) and 9

    /// A semester the pipeline saw with no temporary home: a visit home on
    /// days 20 to 22 cut it into two completed trips, each with a side trip.
    private struct Semester {
        let first: Trip, second: Trip
        let base: [Stay], flights: [Stay]
        let ieper: Stay, bedburg: Stay, station: Stay, visitHome: Stay
    }

    /// With `singleFixVisit` the visit home left one live fix: a home stay
    /// that bounds nothing, so the pipeline kept the semester as one trip.
    private func seedSemester(_ ctx: ModelContext, singleFixVisit: Bool = false) -> Semester {
        stay(ctx, Self.athens, 0.2, 8.8, .home)
        let b1 = stay(ctx, Self.brussels, 10.2, 12.8, .destination)
        let ieper = stay(ctx, Self.ieper, 13.2, 13.8, .destination)
        let b2 = stay(ctx, Self.brussels, 14.2, 19.4, .destination)
        let f1 = stay(ctx, Self.airport, 19.6, 19.7, .transit, airport: true)
        let visitHome = singleFixVisit
            ? stay(ctx, Self.athens, 20.5, 20.5, .home, fixes: 1)
            : stay(ctx, Self.athens, 20.2, 22.5, .home)
        let f2 = stay(ctx, Self.airport, 22.8, 22.9, .transit, airport: true)
        let b3 = stay(ctx, Self.brussels, 23.2, 29.8, .destination)
        let bedburg = stay(ctx, Self.bedburg, 30.2, 32.1, .destination)
        let station = stay(ctx, Self.airport, 32.2, 32.3, .transit)
        let b4 = stay(ctx, Self.brussels, 33.2, 39.4, .destination)
        let f3 = stay(ctx, Self.airport, 39.5, 39.6, .transit, airport: true)
        stay(ctx, Self.athens, 40.2, 44.8, .home)
        let later = [f2, b3, bedburg, station, b4, f3]
        let first = trip(ctx, [b1, ieper, b2, f1] + (singleFixVisit ? later : []))
        return Semester(
            first: first, second: singleFixVisit ? first : trip(ctx, later),
            base: [b1, b2, b3, b4], flights: [f1, f2, f3],
            ieper: ieper, bedburg: bedburg, station: station, visitHome: visitHome)
    }

    @Test("declared late over a semester that a visit home had cut into two completed trips: each becomes its side trip and keeps its id, the base stays are home, and the visit home and its flights make no trip")
    func lateDeclarationOverTwoTripsAndAVisitHome() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let semester = seedSemester(ctx)
        let row = temporaryHome(ctx, from: 10, until: 39.9)
        try ctx.save()
        let (firstID, secondID) = (semester.first.id, semester.second.id)

        let classifier = await makeClassifier(container)
        #expect(await reconcile(classifier, row.id)
                == .committed(stamped: 4, freed: 0, rebuiltTrips: 2, protectedTrips: 0))
        let expected = [
            TripFacts(id: firstID, stays: [semester.ieper.id], start: date(13.2), end: date(13.8),
                      isComplete: true, days: 1),
            TripFacts(id: secondID, stays: [semester.bedburg.id, semester.station.id],
                      start: date(30.2), end: date(32.3), isComplete: true, days: 3),
        ]
        #expect(try trips(container) == expected)
        try expect(semester.base, are: .home, in: nil, container)
        try expect(semester.flights, are: .transit, in: nil, container)
        try expect([semester.visitHome], are: .home, in: nil, container)
        try expect([semester.ieper], are: .destination, in: firstID, container)
        try expect([semester.bedburg], are: .destination, in: secondID, container)
        try expect([semester.station], are: .transit, in: secondID, container)

        // The next ordinary pass has nothing to add.
        let settled = try state(container)
        await ordinaryPass(classifier)
        #expect(try trips(container) == expected)
        #expect(try state(container) == settled)
    }

    @Test("declared late over one completed trip whose visit home left a single fix: the two side trips become two trips, the larger keeps the trip's id, and the single-fix visit home splits nothing and counts as days away")
    func lateDeclarationOverOneTripWithASingleFixVisitHome() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let semester = seedSemester(ctx, singleFixVisit: true)
        let row = temporaryHome(ctx, from: 10, until: 39.9)
        try ctx.save()
        let originalID = semester.first.id

        let classifier = await makeClassifier(container)
        #expect(await reconcile(classifier, row.id)
                == .committed(stamped: 4, freed: 0, rebuiltTrips: 1, protectedTrips: 0))
        await ordinaryPass(classifier)

        let all = try trips(container)
        try #require(all.count == 2)
        #expect(all[0] == TripFacts(id: all[0].id, stays: [semester.ieper.id], start: date(13.2),
                                    end: date(13.8), isComplete: true, days: 1))
        // Bedburg and its station outweigh Ieper, so they keep the id.
        #expect(all[1] == TripFacts(id: originalID, stays: [semester.bedburg.id, semester.station.id],
                                    start: date(30.2), end: date(32.3), isComplete: true, days: 3))
        #expect(all[0].id != originalID)
        try expect(semester.base + [semester.visitHome], are: .home, in: nil, container)
        try expect(semester.flights, are: .transit, in: nil, container)

        // DESIGN section 5: one fix at the real home is not a boundary, so the
        // staying span runs through the visit and its days count as away.
        let utc = TimeZone(secondsFromGMT: 0)!
        let travelling = try TravelDays.labels(container: container, now: date(45), fallbackZone: utc)
        let ledger = try TemporaryHomeLedger.result(
            travelling: travelling, container: container, now: date(45), fallbackZone: utc,
            checkCancellation: {})
        #expect(ledger.away == labels([10...39]))
        #expect(ledger.travelling == labels([13...13, 30...32]))
    }

    @Test("the away ledger for the semester with a real visit home: staying covers the two stretches at the base, travelling the two side trips, away both, and the visit home's own days are none of them")
    func ledgerForTheSemesterWithAVisitHome() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        _ = seedSemester(ctx)
        let row = temporaryHome(ctx, from: 10, until: 39.9)
        try ctx.save()
        let classifier = await makeClassifier(container)
        #expect(await reconcile(classifier, row.id).isSettled)

        let utc = TimeZone(secondsFromGMT: 0)!
        let travelling = try TravelDays.labels(container: container, now: date(45), fallbackZone: utc)
        let ledger = try TemporaryHomeLedger.result(
            travelling: travelling, container: container, now: date(45), fallbackZone: utc,
            checkCancellation: {})
        // Ieper on day 13; Bedburg and the station on days 30 to 32.
        #expect(ledger.travelling == labels([13...13, 30...32]))
        // Day 10 to the flight on day 19, then the flight back on day 22 to
        // the flight home on day 39, less the trip days.
        #expect(ledger.staying == labels([10...12, 14...19, 22...29, 33...39]))
        #expect(ledger.away == labels([10...19, 22...39]))
        // Days 20 and 21 were spent at the real home.
        #expect(ledger.away.isDisjoint(with: labels([20...21])))
        #expect(ledger.stayingByHome == [row.id: ledger.staying])
        #expect(ledger.away.count == 28)
        #expect(ledger.staying.count == 24)
    }

    // MARK: - 3

    @Test("after the temporary home is ended, the semester's stays are still home and a later visit to the same city is a trip")
    func endedThenVisitedAgain() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        let row = temporaryHome(ctx, from: 10, until: nil)
        let semester = [stay(ctx, Self.brussels, 10.2, 25.8, .home),
                        stay(ctx, Self.brussels, 26.2, 39.5, .home)]
        stay(ctx, Self.athens, 41.2, 60.8, .home)
        try ctx.save()

        // The user ends it on day 40.
        row.endedAt = date(40)
        try ctx.save()
        let classifier = await makeClassifier(container)
        #expect(await reconcile(classifier, row.id)
                == .committed(stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 0))

        // A holiday in the same city a month later, then home.
        let visit = [stay(ctx, Self.brussels, 70.2, 71.8), stay(ctx, Self.brussels, 72.2, 73.6)]
        let back = stay(ctx, Self.athens, 74.2, 80.8)
        try ctx.save()
        await ordinaryPass(classifier)

        let all = try trips(container)
        try #require(all.count == 1)
        #expect(all[0] == TripFacts(id: all[0].id, stays: Set(visit.map(\.id)), start: date(70.2),
                                    end: date(73.6), isComplete: true, days: 4))
        try expect(visit, are: .destination, in: all[0].id, container)
        try expect(semester + [back], are: .home, in: nil, container)
    }

    // MARK: - 4

    @Test("moving the end earlier frees a stay at the base that began after the new end, and the ordinary pass makes it a trip; earlier stays stay home")
    func endMovedEarlierFreesALaterBaseStay() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        let row = temporaryHome(ctx, from: 10, until: 100)
        let earlier = [stay(ctx, Self.brussels, 20.2, 22.8, .home, by: row.id),
                       stay(ctx, Self.brussels, 50.2, 52.8, .home, by: row.id)]
        stay(ctx, Self.athens, 61.2, 85.8, .home)
        let later = stay(ctx, Self.brussels, 90.2, 94.8, .home, by: row.id)
        stay(ctx, Self.athens, 96.2, 99.8, .home)
        try ctx.save()

        row.endedAt = date(60)
        try ctx.save()
        let classifier = await makeClassifier(container)
        #expect(await reconcile(classifier, row.id)
                == .committed(stamped: 0, freed: 1, rebuiltTrips: 0, protectedTrips: 0))
        try expect([later], are: .unclassified, in: nil, container)
        try expect(earlier, are: .home, in: nil, container)

        await ordinaryPass(classifier)
        let all = try trips(container)
        try #require(all.count == 1)
        #expect(all[0] == TripFacts(id: all[0].id, stays: [later.id], start: date(90.2),
                                    end: date(94.8), isComplete: true, days: 5))
        try expect([later], are: .destination, in: all[0].id, container)
        try expect(earlier, are: .home, in: nil, container)
    }

    // MARK: - 5

    @Test("removing the temporary home frees its stays, and the ordinary pass rebuilds the semester as one trip of destination stays that carries the side trip's id")
    func removalRebuildsTheSemesterAsATrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        let row = temporaryHome(ctx, from: 10, until: nil)
        let rowID = row.id
        let first = stay(ctx, Self.brussels, 10.2, 12.8, .home, by: rowID)
        let side = stay(ctx, Self.ieper, 13.2, 13.8, .destination)
        let second = stay(ctx, Self.brussels, 14.2, 20.8, .home, by: rowID)
        stay(ctx, Self.athens, 21.2, 30.8, .home)
        let sideTripID = trip(ctx, [side]).id
        try ctx.save()

        try markRemoved(row, ctx, on: 31)
        let classifier = await makeClassifier(container)
        #expect(await reconcile(classifier, rowID)
                == .committed(stamped: 0, freed: 2, rebuiltTrips: 0, protectedTrips: 0))
        try expect([first, second], are: .unclassified, in: nil, container)

        await ordinaryPass(classifier)
        #expect(try trips(container) == [
            TripFacts(id: sideTripID, stays: [first.id, side.id, second.id], start: date(10.2),
                      end: date(20.8), isComplete: true, days: 11),
        ])
        try expect([first, side, second], are: .destination, in: sideTripID, container)
    }

    @Test("removing a temporary home that had two side trips: a favorited smaller side trip stays its own trip with its id while the rest is rebuilt around it; not favorited, it is merged and its id is retired",
          arguments: [true, false])
    func removalKeepsTheSmallerSideTripOnlyWhenFavorited(favorited: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        let row = temporaryHome(ctx, from: 10, until: nil)
        let rowID = row.id
        let base = [stay(ctx, Self.brussels, 10.2, 12.8, .home, by: rowID),
                    stay(ctx, Self.brussels, 14.2, 20.8, .home, by: rowID),
                    stay(ctx, Self.brussels, 24.2, 30.8, .home, by: rowID)]
        let ieper = stay(ctx, Self.ieper, 13.2, 13.8, .destination)
        let bedburg = [stay(ctx, Self.bedburg, 21.2, 22.8, .destination),
                      stay(ctx, Self.airport, 23.2, 23.3, .transit)]
        stay(ctx, Self.athens, 31.2, 40.8, .home)
        let smallerID = trip(ctx, [ieper]).id
        let largerID = trip(ctx, bedburg).id
        try ctx.save()

        try markRemoved(row, ctx, on: 41)
        let classifier = await makeClassifier(container)
        // The favorite is passed the way Settings passes it.
        #expect(await reconcile(classifier, rowID, pinned: favorited ? [smallerID] : [])
                == .committed(stamped: 0, freed: 3, rebuiltTrips: 0,
                              protectedTrips: favorited ? 1 : 0))
        await ordinaryPass(classifier)

        guard favorited else {
            #expect(try trips(container) == [
                TripFacts(id: largerID, stays: Set((base + [ieper] + bedburg).map(\.id)),
                          start: date(10.2), end: date(30.8), isComplete: true, days: 21),
            ])
            return
        }
        #expect(try trips(container) == [
            TripFacts(id: largerID, stays: Set((base + bedburg).map(\.id)),
                      start: date(10.2), end: date(30.8), isComplete: true, days: 21),
            TripFacts(id: smallerID, stays: [ieper.id], start: date(13.2), end: date(13.8),
                      isComplete: true, days: 1),
        ])
        try expect([ieper], are: .destination, in: smallerID, container)
    }

    // MARK: - Kept trips stay kept when stays leave the temporary home

    private struct KeptRow: Equatable {
        let row: PersistentIdentifier
        let id: UUID
        let stays: Set<UUID>
        let categories: [UUID: String]
        let start: Date
        let end: Date?
        let userEdited: Bool
    }

    /// The physical row that carries `id`, with its members and their categories.
    private func keptRow(_ id: UUID, _ container: ModelContainer) throws -> KeptRow? {
        let rows = try ModelContext(container).fetch(FetchDescriptor<Trip>()).filter { $0.id == id }
        guard rows.count == 1, let trip = rows.first else { return nil }
        let members = trip.stays ?? []
        return KeptRow(
            row: trip.persistentModelID, id: trip.id, stays: Set(members.map(\.id)),
            categories: Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.categoryRaw) }),
            start: trip.startDate, end: trip.endDate, userEdited: trip.userEdited)
    }

    @Test("removing a temporary home keeps a favorited side trip that sits between two other side trips: its row, id, stays and categories survive the removal and the next pass, the preview lists it as kept and the two side trips around it as merged, and those are rebuilt into the semester trip")
    func removalKeepsAFavoritedSideTripBetweenTwoOthers() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        // The flight in: tripless, so the unit itself has a stay to regroup.
        let flight = stay(ctx, Self.airport, 9.5, 9.6, .transit, airport: true)
        let row = temporaryHome(ctx, from: 10, until: nil)
        let draft = HomeAnchor(row)
        let base = [stay(ctx, Self.brussels, 10.2, 12.8, .home, by: row.id),
                    stay(ctx, Self.brussels, 14.2, 20.8, .home, by: row.id),
                    stay(ctx, Self.brussels, 24.2, 26.8, .home, by: row.id),
                    stay(ctx, Self.brussels, 28.2, 34.8, .home, by: row.id)]
        let before = stay(ctx, Self.ieper, 13.2, 13.8, .destination)
        let favorite = [stay(ctx, Self.bedburg, 21.2, 22.8, .destination),
                        stay(ctx, Self.airport, 23.2, 23.3, .transit)]
        let after = [stay(ctx, Self.ieper, 27.2, 27.7, .destination),
                     stay(ctx, Self.airport, 27.8, 27.9, .transit)]
        stay(ctx, Self.athens, 35.2, 40.8, .home)
        let beforeID = trip(ctx, [before]).id
        let favoriteID = trip(ctx, favorite).id
        let afterID = trip(ctx, after).id
        try ctx.save()
        let kept = try #require(try keptRow(favoriteID, container))
        #expect(!kept.userEdited)

        let classifier = await makeClassifier(container)
        // What the removal dialog shows before the user confirms.
        let preview = try #require(await classifier.previewTemporaryHomeChange(
            draft: draft, removing: true, pinnedTripIDs: [favoriteID]))
        #expect(preview.staysLeaving == 4)
        #expect(preview.tripsRebuilt.isEmpty)
        // The side trips nobody engaged with fold into the long trip: named, in order.
        #expect(preview.tripsMerged.map(\.id) == [beforeID, afterID])
        #expect(preview.tripsKept.map(\.id) == [favoriteID])
        #expect(preview.tripsKept.first?.reasons == [.pinned])
        #expect(try keptRow(favoriteID, container) == kept, "a preview changes nothing")

        try markRemoved(row, ctx, on: 41)
        #expect(await reconcile(classifier, draft.id, pinned: [favoriteID])
                == .committed(stamped: 0, freed: 4, rebuiltTrips: 0,
                              protectedTrips: preview.tripsKept.count))
        let held = KeptRow(row: kept.row, id: kept.id, stays: kept.stays, categories: kept.categories,
                           start: kept.start, end: kept.end, userEdited: true)
        #expect(try keptRow(favoriteID, container) == held, "after the removal")

        await ordinaryPass(classifier)
        #expect(try keptRow(favoriteID, container) == held, "after the next pass")
        // Everything else between the two stretches at the real home is one
        // trip again, carrying the id of the larger side trip it absorbed.
        #expect(try trips(container) == [
            TripFacts(id: afterID, stays: Set(([flight, before] + base + after).map(\.id)),
                      start: date(9.5), end: date(34.8), isComplete: true, days: 26),
            TripFacts(id: favoriteID, stays: Set(favorite.map(\.id)), start: date(21.2),
                      end: date(23.3), isComplete: true, days: 3),
        ])
        try expect(base + [before], are: .destination, in: afterID, container)
    }

    @Test("moving the end earlier keeps a trip with a hidden photo that sits between the stays that stop being home: its row, id, stays and categories survive the edit and the next pass, while a favorited trip before the new end, whose base stays stay home, is not turned into an edited trip")
    func endMovedEarlierKeepsATripWithAHiddenPhoto() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        let row = temporaryHome(ctx, from: 10, until: 100)
        let earlier = [stay(ctx, Self.brussels, 10.2, 12.8, .home, by: row.id),
                       stay(ctx, Self.brussels, 14.2, 20.8, .home, by: row.id)]
        let untouched = stay(ctx, Self.ieper, 13.2, 13.8, .destination)
        let later = [stay(ctx, Self.brussels, 24.2, 26.8, .home, by: row.id),
                     stay(ctx, Self.brussels, 29.2, 34.8, .home, by: row.id)]
        let curated = [stay(ctx, Self.bedburg, 27.2, 28.5, .destination),
                       stay(ctx, Self.airport, 28.6, 28.7, .transit)]
        stay(ctx, Self.athens, 35.2, 40.8, .home)
        let untouchedID = trip(ctx, [untouched]).id
        let curatedID = trip(ctx, curated).id
        ctx.insert(HiddenPhoto(localIdentifier: "asset-1", tripID: curatedID))
        try ctx.save()
        let kept = try #require(try keptRow(curatedID, container))
        let favorite = try #require(try keptRow(untouchedID, container))

        // The user moves the end to day 22.
        row.endedAt = date(22)
        try ctx.save()
        let classifier = await makeClassifier(container)
        #expect(await reconcile(classifier, row.id, pinned: [untouchedID])
                == .committed(stamped: 0, freed: 2, rebuiltTrips: 0, protectedTrips: 1))
        let held = KeptRow(row: kept.row, id: kept.id, stays: kept.stays, categories: kept.categories,
                           start: kept.start, end: kept.end, userEdited: true)
        for round in ["after the edit", "after the next pass"] {
            #expect(try keptRow(curatedID, container) == held, "\(round)")
            // Its base stays on both sides are still home: nothing threatens it.
            #expect(try keptRow(untouchedID, container) == favorite, "\(round)")
            try expect(earlier, are: .home, in: nil, container)
            await ordinaryPass(classifier)
        }
        // The freed stays are a trip of their own around the kept one.
        let all = try trips(container)
        try #require(all.count == 3)
        #expect(all[1] == TripFacts(id: all[1].id, stays: Set(later.map(\.id)), start: date(24.2),
                                    end: date(34.8), isComplete: true, days: 11))
        #expect(try ModelContext(container).fetch(FetchDescriptor<HiddenPhoto>()).map(\.tripID)
                == [curatedID])
    }

    @Test("removing a temporary home does not turn a favorited trip into an edited one when no stay that stops being home is near it")
    func removalLeavesADistantFavoriteUnmarked() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        let row = temporaryHome(ctx, from: 10, until: 30)
        let rowID = row.id
        stay(ctx, Self.brussels, 10.2, 20.8, .home, by: rowID)
        stay(ctx, Self.athens, 31.2, 49.8, .home)
        // A holiday months later, between two stretches at the real home.
        let holiday = stay(ctx, Self.vienna, 50.2, 52.8, .destination)
        stay(ctx, Self.athens, 53.2, 60.8, .home)
        let holidayID = trip(ctx, [holiday]).id
        try ctx.save()
        let before = try #require(try keptRow(holidayID, container))

        try markRemoved(row, ctx, on: 61)
        let classifier = await makeClassifier(container)
        #expect(await reconcile(classifier, rowID, pinned: [holidayID])
                == .committed(stamped: 0, freed: 1, rebuiltTrips: 0, protectedTrips: 0))
        #expect(try keptRow(holidayID, container) == before)
        await ordinaryPass(classifier)
        #expect(try keptRow(holidayID, container) == before)
        #expect(!before.userEdited)
    }

    // MARK: - A wrong pin corrected

    @Test("moving a temporary home's pin to the right city through the form's save: the stays at the wrong place stop being home and become trips again, the stays at the right place become home and the trip that held them is rebuilt into its side trip with its id, and a favorited trip taken between the stays at the wrong place keeps its row, id, stays and categories and is measured from the real home")
    func pinMovedToTheRightCityThroughTheSave() async throws {
        let suite = "TemporaryHomeJourneyTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        // Declared in Vienna by mistake; the stays there were stamped home.
        let row = temporaryHome(ctx, "Erasmus", at: Self.vienna, from: 10, until: nil)
        let rowID = row.id
        let wrong = [stay(ctx, Self.vienna, 10.2, 12.8, .home, by: rowID),
                     stay(ctx, Self.vienna, 15.2, 19.8, .home, by: rowID),
                     stay(ctx, Self.vienna, 30.2, 33.8, .home, by: rowID)]
        let favorite = stay(ctx, Self.brno, 13.2, 14.8, .destination)
        // The real base: a trip, as the pipeline saw it with the pin elsewhere.
        let right = [stay(ctx, Self.brussels, 20.2, 22.8, .destination),
                     stay(ctx, Self.brussels, 24.2, 29.8, .destination)]
        let side = stay(ctx, Self.ieper, 23.2, 23.8, .destination)
        stay(ctx, Self.athens, 35.2, 40.8, .home)
        let favoriteID = trip(ctx, [favorite]).id
        let plainID = trip(ctx, [right[0], side, right[1]]).id
        try ctx.save()
        let kept = try #require(try keptRow(favoriteID, container))
        #expect(!kept.userEdited)

        // The form's save with the pin on Brussels, then its reconciliation.
        let moved = TemporaryHomeSaveWorker.apply(
            TemporaryHomeSavePayload(
                target: .edit(rowID), label: "Erasmus",
                latitude: Self.brussels.lat, longitude: Self.brussels.lon,
                locality: "Brussels", administrativeArea: nil, country: "Belgium",
                isoCountryCode: "BE", startedAt: date(10), endedAt: nil,
                timeZoneIdentifier: "GMT", now: date(41)),
            context: ModelContext(container), pendingDefaults: defaults)
        #expect(moved.pendingReconciliation?.id == rowID)

        let classifier = await makeClassifier(container)
        #expect(await reconcile(classifier, rowID, pinned: [favoriteID])
            == .committed(stamped: 2, freed: 3, rebuiltTrips: 1, protectedTrips: 1))
        try expect(wrong, are: .unclassified, in: nil, container)
        try expect(right, are: .home, in: nil, container)
        try expect([side], are: .destination, in: plainID, container)
        let held = KeptRow(row: kept.row, id: kept.id, stays: kept.stays, categories: kept.categories,
                           start: kept.start, end: kept.end, userEdited: true)
        #expect(try keptRow(favoriteID, container) == held, "after the move")

        await ordinaryPass(classifier)
        #expect(try keptRow(favoriteID, container) == held, "after the next pass")
        try expect(right, are: .home, in: nil, container)
        // The stays at the wrong place are trips again, around the kept one.
        let all = try trips(container)
        try #require(all.count == 4)
        #expect(all[0] == TripFacts(id: all[0].id, stays: [wrong[0].id, wrong[1].id],
                                    start: date(10.2), end: date(19.8), isComplete: true, days: 10))
        #expect(all[1] == TripFacts(id: favoriteID, stays: [favorite.id], start: date(13.2),
                                    end: date(14.8), isComplete: true, days: 2))
        #expect(all[2] == TripFacts(id: plainID, stays: [side.id], start: date(23.2),
                                    end: date(23.8), isComplete: true, days: 1))
        #expect(all[3] == TripFacts(id: all[3].id, stays: [wrong[2].id], start: date(30.2),
                                    end: date(33.8), isComplete: true, days: 4))
        try expect([wrong[0], wrong[1]], are: .destination, in: all[0].id, container)
        try expect([wrong[2]], are: .destination, in: all[3].id, container)
        // The favorite left from the real home: Athens to its town is about 1,370 km.
        let measured = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>())
            .first { $0.id == favorite.id })
        #expect(abs(measured.distanceFromHomeKm - 1_370) < 60, "\(measured.distanceFromHomeKm) km")
    }

    // MARK: - Corrections taught to a temporary home

    @Test("removing a temporary home withdraws a This Wasn't a Trip correction taught to it: the demoted day trip's stay is freed with the base stays, no correction keyed to the removed temporary home remains, a correction of the real home stays, and the next pass rebuilds one trip that holds the day trip")
    func removalWithdrawsTheCorrectionsTaughtToIt() async throws {
        let suite = "TemporaryHomeJourneyTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let athens = Home(label: "Athens", latitude: Self.athens.lat, longitude: Self.athens.lon,
                          radiusKm: 25, startedAt: date(-1000))
        ctx.insert(athens)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        let row = temporaryHome(ctx, from: 10, until: nil)
        let rowID = row.id
        let base = [stay(ctx, Self.brussels, 10.2, 12.8, .home, by: rowID),
                    stay(ctx, Self.brussels, 14.2, 20.8, .home, by: rowID)]
        // A day trip about 50 km from the base.
        let outing = stay(ctx, (51.30, 4.35), 13.2, 13.8, .destination)
        stay(ctx, Self.athens, 21.2, 30.8, .home)
        let outingTrip = trip(ctx, [outing])
        // An earlier correction of the real home's, which must outlive the removal.
        let realHomeCorrection = HomeAreaOverride(
            kind: .include, centerLatitude: 38.3, centerLongitude: 23.8, radiusKm: 2,
            homeID: athens.id)
        ctx.insert(realHomeCorrection)
        try ctx.save()
        let (outingTripID, outingRow, outingName, realHomeCorrectionID) = (
            outingTrip.id, outingTrip.persistentModelID, outingTrip.displayName,
            realHomeCorrection.id)

        // "This wasn't a trip" on the day trip, while the temporary home stands.
        let classifier = await makeClassifier(container)
        #expect(await classifier.demoteTripToHomeArea(tripID: outingTripID, tripIdentifier: outingRow)
                == .demoted(tripName: outingName))
        let reader = ModelContext(container)
        #expect(try reader.fetch(FetchDescriptor<HomeAreaOverride>())
            .filter { $0.homeID == rowID }.count == 1)
        let demoted = try #require(try reader.fetch(FetchDescriptor<Stay>()).first { $0.id == outing.id })
        #expect(demoted.category == .home)
        #expect(demoted.userOverridden)
        #expect(demoted.temporaryHomeID == rowID)

        // Remove Temporary Home, as Settings writes it, then its reconciliation.
        let removal = TemporaryHomeSaveWorker.apply(
            .removing(rowID, now: date(40)), context: ModelContext(container),
            pendingDefaults: defaults)
        #expect(!removal.failed)
        #expect(removal.pendingReconciliation?.id == rowID)
        #expect(await reconcile(classifier, rowID)
                == .committed(stamped: 0, freed: 3, rebuiltTrips: 0, protectedTrips: 0))

        let after = ModelContext(container)
        #expect(try after.fetch(FetchDescriptor<HomeAreaOverride>()).map(\.id) == [realHomeCorrectionID])
        let freed = try #require(try after.fetch(FetchDescriptor<Stay>()).first { $0.id == outing.id })
        #expect(freed.category == .unclassified)
        #expect(!freed.userOverridden)

        await ordinaryPass(classifier)
        let all = try trips(container)
        try #require(all.count == 1)
        #expect(all[0] == TripFacts(id: all[0].id, stays: Set((base + [outing]).map(\.id)),
                                    start: date(10.2), end: date(20.8), isComplete: true, days: 11))
        try expect(base + [outing], are: .destination, in: all[0].id, container)
    }

    // MARK: - 6

    @Test("a favorited trip and a renamed trip inside the dates are split like an untouched trip beside them, through the declaration and the next pass: each is archived with its name, its stay at the base is home, and its side trip is a trip of its own with a fresh id, while the untouched trip's side trip keeps its id")
    func pinnedAndRenamedTripsAreSplit() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        let pinned = [stay(ctx, Self.brussels, 10.2, 12.8, .destination),
                      stay(ctx, Self.ieper, 13.2, 13.8, .destination)]
        stay(ctx, Self.athens, 15.2, 19.8, .home)
        let renamed = [stay(ctx, Self.brussels, 20.2, 22.8, .destination),
                       stay(ctx, Self.bedburg, 23.2, 24.8, .destination)]
        stay(ctx, Self.athens, 26.2, 29.8, .home)
        let plain = [stay(ctx, Self.brussels, 30.2, 32.8, .destination),
                     stay(ctx, Self.ieper, 33.2, 33.8, .destination)]
        stay(ctx, Self.athens, 35.2, 39.8, .home)
        let pinnedTrip = trip(ctx, pinned)
        let renamedTrip = trip(ctx, renamed)
        // What the rename sheet writes.
        renamedTrip.customName = "Erasmus week"
        renamedTrip.userEdited = true
        let plainTrip = trip(ctx, plain)
        let row = temporaryHome(ctx, from: 10, until: 100)
        try ctx.save()
        let (pinnedID, renamedID, plainID) = (pinnedTrip.id, renamedTrip.id, plainTrip.id)

        let classifier = await makeClassifier(container)
        // The archives reach the queue through the sink only, never the parked belt.
        let sink = SAParkedBox()
        await classifier.setDissolvedRecordSink { sink.append($0) }
        #expect(await reconcile(classifier, row.id, pinned: [pinnedID])
                == .committed(stamped: 3, freed: 0, rebuiltTrips: 3, protectedTrips: 0))
        #expect(await classifier.drainParkedDissolvedTrips().isEmpty)
        let archived = sink.all
        let archivedIDs: Set<UUID> = Set(archived.map(\.id))
        #expect(archivedIDs == [pinnedID, renamedID])
        #expect(archived.first { $0.id == renamedID }?.customName == "Erasmus week")
        #expect(archived.first { $0.id == pinnedID }?.wasFavourite == true)
        let pieces = try trips(container)
        #expect(pieces.map(\.stays) == [[pinned[1].id], [renamed[1].id], [plain[1].id]])
        #expect(pieces[2].id == plainID)
        #expect(!pieces.contains { $0.id == pinnedID || $0.id == renamedID })
        for round in ["after the declaration", "after the next pass"] {
            #expect(try trips(container) == pieces, "\(round)")
            try expect([pinned[0], renamed[0], plain[0]], are: .home, in: nil, container)
            try expect([pinned[1]], are: .destination, in: pieces[0].id, container)
            try expect([renamed[1]], are: .destination, in: pieces[1].id, container)
            try expect([plain[1]], are: .destination, in: plainID, container)
            await ordinaryPass(classifier)
        }
    }

    // MARK: - 7

    @Test("two temporary homes one after the other with weeks at the real home between them: each base's stays are home and owned by its own temporary home, each semester has its side trip, and the weeks between are days at home")
    func twoSemestersWithTheRealHomeBetween() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.8, .home)
        let autumn = temporaryHome(ctx, "Brussels", at: Self.brussels, from: 10, until: 60)
        let spring = temporaryHome(ctx, "Vienna", at: Self.vienna, from: 100, until: 160)
        let brusselsStays = [stay(ctx, Self.brussels, 10.2, 20.8), stay(ctx, Self.brussels, 23.2, 59.8)]
        let ieperStay = stay(ctx, Self.ieper, 21.2, 22.8)
        let between = [stay(ctx, Self.athens, 61.2, 80.8), stay(ctx, Self.athens, 81.2, 99.5)]
        let viennaStays = [stay(ctx, Self.vienna, 100.2, 120.8), stay(ctx, Self.vienna, 124.2, 159.8)]
        let brnoStay = stay(ctx, Self.brno, 121.2, 123.8)
        let back = stay(ctx, Self.athens, 161.2, 170.8)
        try ctx.save()

        let classifier = await makeClassifier(container)
        await ordinaryPass(classifier)

        try expect(brusselsStays + viennaStays + between + [back], are: .home, in: nil, container)
        let all = try trips(container)
        try #require(all.count == 2)
        #expect(all[0] == TripFacts(id: all[0].id, stays: [ieperStay.id], start: date(21.2),
                                    end: date(22.8), isComplete: true, days: 2))
        #expect(all[1] == TripFacts(id: all[1].id, stays: [brnoStay.id], start: date(121.2),
                                    end: date(123.8), isComplete: true, days: 3))
        try expect([ieperStay], are: .destination, in: all[0].id, container)
        try expect([brnoStay], are: .destination, in: all[1].id, container)

        // Each home stay records the anchor it was at.
        let committed = ModelContext(container)
        let known = Set(try committed.fetch(FetchDescriptor<TemporaryHome>()).map(\.id))
        func owner(_ stay: Stay) throws -> HomeAnchors.RecordedOwner? {
            let id = stay.id
            return try committed.fetch(FetchDescriptor<Stay>(predicate: #Predicate { $0.id == id }))
                .first.map {
                    HomeAnchors.recordedOwner(
                        temporaryHomeID: $0.temporaryHomeID, knownTemporaryHomeIDs: known)
                }
        }
        #expect(try brusselsStays.map(owner) == [.temporary(autumn.id), .temporary(autumn.id)])
        #expect(try viennaStays.map(owner) == [.temporary(spring.id), .temporary(spring.id)])
        #expect(try (between + [back]).map(owner) == [.realHome, .realHome, .realHome])

        let utc = TimeZone(secondsFromGMT: 0)!
        let travelling = try TravelDays.labels(container: container, now: date(175), fallbackZone: utc)
        let ledger = try TemporaryHomeLedger.result(
            travelling: travelling, container: container, now: date(175), fallbackZone: utc,
            checkCancellation: {})
        #expect(ledger.travelling == labels([21...22, 121...123]))
        #expect(ledger.stayingByHome == [
            autumn.id: labels([10...20, 23...59]),
            spring.id: labels([100...120, 124...159]),
        ])
        #expect(ledger.away == labels([10...59, 100...159]))
        #expect(ledger.away.count == 110)
    }

    // MARK: - 8

    @Test("a temporary home declared before its start changes nothing, an earlier holiday in the same city stays a trip, and the stays that later begin inside its dates are home")
    func declaredInAdvance() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 2.8, .home)
        let holiday = stay(ctx, Self.brussels, 3.2, 5.8, .destination)
        stay(ctx, Self.athens, 6.2, 9.8, .home)
        let holidayTripID = trip(ctx, [holiday]).id
        // Day 9: the user adds next semester's temporary home, starting tomorrow.
        let row = temporaryHome(ctx, from: 10, until: 100)
        try ctx.save()
        let before = try state(container)

        let classifier = await makeClassifier(container)
        #expect(await reconcile(classifier, row.id)
                == .committed(stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 0))
        await ordinaryPass(classifier)
        #expect(try state(container) == before)

        let semester = [stay(ctx, Self.brussels, 10.2, 14.8), stay(ctx, Self.brussels, 15.2, 19.8)]
        try ctx.save()
        await ordinaryPass(classifier)
        try expect(semester, are: .home, in: nil, container)
        #expect(try trips(container) == [
            TripFacts(id: holidayTripID, stays: [holiday.id], start: date(3.2), end: date(5.8),
                      isComplete: true, days: 3),
        ])
        try expect([holiday], are: .destination, in: holidayTripID, container)
    }

    // MARK: - Late declaration and the trips it rebuilds or keeps

    /// A day trip to Ieper with a 43-minute stop at a station on the way
    /// out and on the way back, between two stretches at the base.
    private func seedDayTripWithStations(
        _ ctx: ModelContext, _ category: StayCategory, km: (station: Double, town: Double)
    ) -> (base: [Stay], trip: [Stay]) {
        let station: Place = (51.35, 4.35)
        let first = stay(ctx, Self.brussels, 10.2, 12.8, category)
        let out = stay(ctx, station, 13.20, 13.23, category)
        let town = stay(ctx, Self.ieper, 13.25, 13.75, category)
        let back = stay(ctx, station, 13.77, 13.80, category)
        let second = stay(ctx, Self.brussels, 14.2, 20.8, category)
        out.distanceFromHomeKm = km.station
        back.distanceFromHomeKm = km.station
        town.distanceFromHomeKm = km.town
        return ([first, second], [out, town, back])
    }

    private func categories(_ stays: [Stay], _ container: ModelContainer) throws -> [String] {
        let rows = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        return stays.map { stay in rows.first { $0.id == stay.id }?.categoryRaw ?? "missing" }
    }

    @Test("a side trip's station stops are transit whether the temporary home was declared on arrival or late: declared late, the stops that were destinations inside the big trip are judged again from the base")
    func lateDeclarationRejudgesTheSideTripsStationStops() async throws {
        // Declared on arrival: the stays arrive unclassified, measured from the base.
        let onArrival = try TestSupport.makeInMemoryContainer()
        var ctx = ModelContext(onArrival)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        _ = temporaryHome(ctx, from: 10, until: nil)
        let fresh = seedDayTripWithStations(ctx, .unclassified, km: (55, 111))
        try ctx.save()
        await ordinaryPass(await makeClassifier(onArrival))
        try expect(fresh.base, are: .home, in: nil, onArrival)
        #expect(try categories(fresh.trip, onArrival) == ["transit", "destination", "transit"])
        #expect(try trips(onArrival).map(\.stays) == [Set(fresh.trip.map(\.id))])

        // Declared late: the same stays as an earlier pass left them, every
        // one a destination of one completed trip measured from Athens.
        let late = try TestSupport.makeInMemoryContainer()
        ctx = ModelContext(late)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        let settled = seedDayTripWithStations(ctx, .destination, km: (2_050, 2_100))
        stay(ctx, Self.athens, 21.2, 30.8, .home)
        let big = trip(ctx, [settled.base[0]] + settled.trip + [settled.base[1]])
        let row = temporaryHome(ctx, from: 10, until: nil)
        try ctx.save()
        let bigID = big.id
        let classifier = await makeClassifier(late)
        #expect(await reconcile(classifier, row.id)
                == .committed(stamped: 2, freed: 0, rebuiltTrips: 1, protectedTrips: 0))
        await ordinaryPass(classifier)
        try expect(settled.base, are: .home, in: nil, late)
        #expect(try trips(late).map(\.stays) == [Set(settled.trip.map(\.id))])
        #expect(try trips(late).map(\.id) == [bigID])

        // Declared late equals declared on arrival, stay for stay.
        #expect(try categories(settled.trip, late) == categories(fresh.trip, onArrival))
        #expect(try categories(settled.trip, late) == ["transit", "destination", "transit"])
    }

    @Test("a renamed open trip the user kept against a late declaration keeps its stays, id, name and categories, closes at the next stay at the base, and still lists the base city, where most of its time was spent")
    func renamedOpenTripClosesAtTheNextReturn() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        let members = [stay(ctx, Self.brussels, 10.2, 12.8, .destination),
                       stay(ctx, Self.ieper, 13.2, 13.8, .destination),
                       stay(ctx, Self.brussels, 14.2, 15.8, .destination)]
        for (member, name) in zip(members, ["Brussels", "Ieper", "Brussels"]) { member.locality = name }
        let renamed = trip(ctx, members)
        renamed.isComplete = false
        renamed.endDate = nil
        renamed.customName = "Erasmus"
        renamed.userEdited = true
        renamed.recomputeSummary()
        try ctx.save()
        let renamedID = renamed.id
        #expect(renamed.destinationSummary == "Brussels, Ieper")

        let row = temporaryHome(ctx, from: 10, until: 100)
        row.locality = "Brussels"
        // Only an explicit keep holds a trip the temporary home covers whole.
        row.addKeptTrip(renamedID)
        try ctx.save()
        let classifier = await makeClassifier(container)
        #expect(await reconcile(classifier, row.id)
                == .committed(stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 1))

        // The next stay at the base arrives.
        let next = stay(ctx, Self.brussels, 16.2, 20.8)
        next.locality = "Brussels"
        try ctx.save()
        await ordinaryPass(classifier)

        try expect([next], are: .home, in: nil, container)
        #expect(try trips(container) == [
            TripFacts(id: renamedID, stays: Set(members.map(\.id)), start: date(10.2),
                      end: date(15.8), isComplete: true, days: 6),
        ])
        try expect(members, are: .destination, in: renamedID, container)
        let closed = try #require(try ModelContext(container).fetch(FetchDescriptor<Trip>()).first)
        #expect(closed.customName == "Erasmus")
        #expect(closed.userEdited)
        #expect(closed.destinationSummary == "Brussels, Ieper")
    }
}

// MARK: - History older than the real home's record

extension TemporaryHomeJourneyTests {
    /// The real home's record starts long after the fixture (history was
    /// imported); the temporary home is declared for a past period.
    private func seedLateAthens(_ ctx: ModelContext) -> Home {
        let athens = Home(label: "Athens", latitude: Self.athens.lat, longitude: Self.athens.lon,
                          radiusKm: 25, startedAt: date(1000))
        ctx.insert(athens)
        return athens
    }

    @Test("This Wasn't a Trip on an outing near the real home, before its record and inside a backdated temporary home's dates, teaches the real home; one near the base teaches the base")
    func demotionInPrehistoryTeachesTheNearerHome() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let athensID = seedLateAthens(ctx).id
        let rowID = temporaryHome(ctx, from: 10, until: 200).id
        stay(ctx, Self.athens, 100.2, 101.8, .home)
        // A village about 16 km from the Athens pin.
        let nearHome = trip(ctx, [stay(ctx, (38.0, 23.99), 102.2, 102.8, .destination)])
        stay(ctx, Self.athens, 103.2, 104.8, .home)
        stay(ctx, Self.brussels, 110.2, 111.8, .home)
        // A day trip about 50 km from the base.
        let nearBase = trip(ctx, [stay(ctx, (51.30, 4.35), 112.2, 112.8, .destination)])
        stay(ctx, Self.brussels, 113.2, 114.8, .home)
        try ctx.save()
        let outings = [(nearHome.id, nearHome.persistentModelID, nearHome.displayName),
                       (nearBase.id, nearBase.persistentModelID, nearBase.displayName)]

        let classifier = await makeClassifier(container)
        var owners: [UUID?] = []
        for (id, row, name) in outings {
            #expect(await classifier.demoteTripToHomeArea(tripID: id, tripIdentifier: row)
                    == .demoted(tripName: name))
            let taught = try ModelContext(container).fetch(FetchDescriptor<HomeAreaOverride>())
            owners.append(taught.first { !owners.contains($0.homeID) }?.homeID)
        }
        #expect(owners == [athensID, rowID])
    }

    @Test("a trip taken from the real home before its record, inside a backdated temporary home's dates, is measured from the real home although the base is nearer the destination")
    func tripFromTheRealHomeInPrehistoryIsMeasuredFromIt() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        _ = seedLateAthens(ctx)
        _ = temporaryHome(ctx, from: 10, until: 200)
        stay(ctx, Self.athens, 100.2, 101.8, .home)
        // Paris: about 260 km from Brussels, about 2,100 km from Athens.
        let paris = stay(ctx, (48.86, 2.35), 102.2, 104.8)
        stay(ctx, Self.athens, 105.2, 106.8, .home)
        try ctx.save()

        await ordinaryPass(await makeClassifier(container))
        let measured = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>())
            .first { $0.id == paris.id })
        #expect(measured.trip != nil)
        #expect(abs(measured.distanceFromHomeKm - 2_100) < 100, "\(measured.distanceFromHomeKm) km")
    }

    @Test("a trip that starts inside a backdated temporary home's dates, after a real-home stay that began before them, is measured from the real home too")
    func tripStartingInsideTheDatesAfterAnEarlierRealHomeStay() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        _ = seedLateAthens(ctx)
        // The start is picked as the day of the move; the last night at home began before it.
        _ = temporaryHome(ctx, from: 101, until: 200)
        stay(ctx, Self.athens, 100.2, 101.8, .home)
        let paris = stay(ctx, (48.86, 2.35), 102.2, 104.8)
        stay(ctx, Self.brussels, 105.2, 106.8, .home)
        try ctx.save()

        await ordinaryPass(await makeClassifier(container))
        let measured = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>())
            .first { $0.id == paris.id })
        #expect(measured.trip != nil)
        #expect(abs(measured.distanceFromHomeKm - 2_100) < 100, "\(measured.distanceFromHomeKm) km")
    }

    @Test("moving the pin frees the stays at the old place beside a favorited trip; stays the same save stamps home at the new place stand between them, so the favorite is not marked edited")
    func pinMoveDoesNotMarkAFavoriteTheNewBoundariesKeepApart() async throws {
        let suite = "TemporaryHomeJourneyTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        let rowID = temporaryHome(ctx, "Erasmus", at: Self.brussels, from: 10, until: 100).id
        let old = [stay(ctx, Self.brussels, 10.2, 11.8, .home, by: rowID),
                   stay(ctx, Self.brussels, 16.2, 17.8, .home, by: rowID)]
        // Not assembled yet, as an import leaves them.
        let new = [stay(ctx, Self.vienna, 12.2, 12.8, .destination),
                   stay(ctx, Self.vienna, 15.2, 15.8, .destination)]
        // Measured from the base it left: Brussels to its town is about 910 km.
        let favorite = stay(ctx, Self.brno, 13.2, 14.8, .destination)
        favorite.distanceFromHomeKm = 910
        let favoriteID = trip(ctx, [favorite]).id
        stay(ctx, Self.athens, 20.2, 21.8, .home)
        try ctx.save()
        let kept = try #require(try keptRow(favoriteID, container))

        let moved = TemporaryHomeSaveWorker.apply(
            TemporaryHomeSavePayload(
                target: .edit(rowID), label: "Erasmus",
                latitude: Self.vienna.lat, longitude: Self.vienna.lon,
                locality: "Vienna", administrativeArea: nil, country: "Austria",
                isoCountryCode: "AT", startedAt: date(10), endedAt: date(100),
                timeZoneIdentifier: "GMT", now: date(41)),
            context: ModelContext(container), pendingDefaults: defaults)
        #expect(moved.pendingReconciliation?.id == rowID)

        let classifier = await makeClassifier(container)
        #expect(await reconcile(classifier, rowID, pinned: [favoriteID])
            == .committed(stamped: 2, freed: 2, rebuiltTrips: 0, protectedTrips: 0))
        try expect(new, are: .home, in: nil, container)
        try expect(old, are: .unclassified, in: nil, container)
        #expect(try keptRow(favoriteID, container) == kept, "after the move")

        // The freed stays become trips again on either side of it.
        await ordinaryPass(classifier)
        #expect(try keptRow(favoriteID, container) == kept, "after the next pass")
        let all = try trips(container)
        #expect(all.map(\.stays) == [[old[0].id], [favorite.id], [old[1].id]])
        // It now leaves the new place: Vienna to its town is about 111 km.
        let measured = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>())
            .first { $0.id == favorite.id })
        #expect(abs(measured.distanceFromHomeKm - 111) < 30, "\(measured.distanceFromHomeKm) km")
    }
}

// MARK: - Kept trips stay kept

extension TemporaryHomeJourneyTests {
    /// Both marks of every physical row that carries `id`.
    private func marks(_ id: UUID, _ container: ModelContainer) throws -> [[Bool]] {
        try ModelContext(container).fetch(FetchDescriptor<Trip>()).filter { $0.id == id }
            .map { [$0.userEdited, $0.keptByTemporaryHome] }
    }

    @Test("a favorited open trip wholly at the base: the preview lists it as split, the unit archives it and its stays become home, and the next ordinary pass, with the next stay at the base, makes no trip of them")
    func favoritedOpenTripAtTheBaseIsArchived() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        let first = stay(ctx, Self.brussels, 10.2, 12.8, .destination)
        let second = stay(ctx, Self.brussels, 14.2, 15.8, .destination)
        let open = trip(ctx, [first, second])
        open.isComplete = false
        open.endDate = nil
        let id = open.id
        let base = temporaryHome(ctx, from: 10, until: nil)
        try ctx.save()

        let classifier = await makeClassifier(container)
        let preview = try #require(await classifier.previewTemporaryHomeChange(
            draft: HomeAnchor(base), removing: false, pinnedTripIDs: [id]))
        #expect(preview.tripsKept.isEmpty)
        #expect(preview.tripsSplit.map(\.id) == [id])
        #expect(preview.tripsSplit.first?.end == nil)
        #expect(preview.tripsSplit.first?.reasons == [.pinned])
        // The archive reaches the queue through the sink only, never the parked belt.
        let sink = SAParkedBox()
        await classifier.setDissolvedRecordSink { sink.append($0) }
        #expect(await reconcile(classifier, base.id, pinned: [id])
                == .committed(stamped: 2, freed: 0, rebuiltTrips: preview.tripsSplit.count,
                              protectedTrips: 0))
        #expect(await classifier.drainParkedDissolvedTrips().isEmpty)
        let archived = sink.all
        #expect(archived.map(\.id) == [id])
        #expect(archived.first?.isComplete == false)
        #expect(archived.first?.stays.map(\.id) == [first.id, second.id])
        #expect(try marks(id, container).isEmpty)
        try expect([first, second], are: .home, in: nil, container)

        // The next stay at the base arrives.
        let live = ModelContext(container)
        let next = stay(live, Self.brussels, 16.2, 20.8)
        try live.save()
        await ordinaryPass(classifier)
        #expect(try trips(container).isEmpty)
        try expect([first, second, next], are: .home, in: nil, container)
    }

    @Test("a favorited completed trip wholly at the base that the user kept against the temporary home is marked as this feature's and keeps its id and members after a late destination inside its dates and an ordinary pass")
    func favoritedCompletedTripAtTheBaseSurvivesALateStayInsideIt() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        let first = stay(ctx, Self.brussels, 10.2, 12.8, .destination)
        let second = stay(ctx, Self.brussels, 14.2, 15.8, .destination)
        let id = trip(ctx, [first, second]).id
        stay(ctx, Self.athens, 20.2, 25, .home)
        let base = temporaryHome(ctx, from: 10, until: 19)
        // Only an explicit keep holds a trip the temporary home covers whole.
        base.addKeptTrip(id)
        try ctx.save()
        let kept = try #require(try keptRow(id, container))

        let classifier = await makeClassifier(container)
        #expect(await reconcile(classifier, base.id, pinned: [id])
                == .committed(stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 1))
        let held = KeptRow(row: kept.row, id: kept.id, stays: kept.stays, categories: kept.categories,
                           start: kept.start, end: kept.end, userEdited: true)
        #expect(try keptRow(id, container) == held, "after the unit")

        // A photo of day 13 arrives later, already judged a destination by its import.
        let late = ModelContext(container)
        stay(late, Self.brussels, 13.0, 13.4, .destination)
        try late.save()
        await ordinaryPass(classifier)
        #expect(try keptRow(id, container) == held, "after the next pass")
        #expect(try marks(id, container) == [[true, true]])
    }

    /// Where the kept trip sits: forward, the new temporary home claims its
    /// members and the user kept it against it; reverse, the removal frees
    /// the stays around it.
    nonisolated enum KeptCase: String, CaseIterable, Sendable {
        case forwardOpen, forwardCompleted, reverseOpen, reverseCompleted
        var isOpen: Bool { self == .forwardOpen || self == .reverseOpen }
        var isReverse: Bool { self == .reverseOpen || self == .reverseCompleted }
    }

    @Test("every kind of engagement keeps a trip a temporary home change touches, open or completed, forward (kept by the user against it) or reverse: it is marked, and its row, id, members and categories survive the unit, the follow-up pass and five more ordinary passes with a late stay inside it",
          arguments: TripClassifier.TripInteraction.allCases, KeptCase.allCases)
    func everyInteractionKeepsTheTripItTouches(
        interaction: TripClassifier.TripInteraction, place: KeptCase
    ) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        let row = temporaryHome(ctx, from: 10, until: nil)
        let rowID = row.id
        let members: [Stay]
        if place.isReverse {
            stay(ctx, Self.brussels, 10.2, 12.8, .home, by: rowID)
            members = [stay(ctx, Self.ieper, 13.2, 13.8, .destination),
                       stay(ctx, Self.ieper, 14.2, 14.8, .destination)]
            if !place.isOpen {
                stay(ctx, Self.brussels, 15.2, 19.8, .home, by: rowID)
                stay(ctx, Self.athens, 21.2, 30.8, .home)
            }
        } else {
            members = [stay(ctx, Self.brussels, 10.2, 12.8, .destination),
                       stay(ctx, Self.ieper, 13.2, 13.8, .destination),
                       stay(ctx, Self.brussels, 14.2, 15.8, .destination)]
            if !place.isOpen { stay(ctx, Self.athens, 20.2, 25, .home) }
        }
        let engaged = trip(ctx, members)
        if place.isOpen {
            engaged.isComplete = false
            engaged.endDate = nil
        }
        let id = engaged.id
        switch interaction {
        case .userEdited: engaged.userEdited = true
        case .customName: engaged.customName = "Erasmus"
        case .pinned: break
        case .hiddenPhoto: ctx.insert(HiddenPhoto(localIdentifier: "asset-1", tripID: id))
        case .pinnedPhoto: ctx.insert(PinnedPhoto(localIdentifier: "asset-2", tripID: id))
        case .stayOverridden: members[1].userOverridden = true
        }
        // Only an explicit keep holds a trip the temporary home covers whole.
        if !place.isReverse { row.addKeptTrip(id) }
        try ctx.save()
        let kept = try #require(try keptRow(id, container))
        if place.isReverse { try markRemoved(row, ctx, on: 40) }

        let classifier = await makeClassifier(container)
        let freed = place.isReverse ? (place.isOpen ? 1 : 2) : 0
        #expect(await reconcile(classifier, rowID, pinned: interaction == .pinned ? [id] : [])
                == .committed(stamped: 0, freed: freed, rebuiltTrips: 0, protectedTrips: 1))
        let held = KeptRow(row: kept.row, id: kept.id, stays: kept.stays, categories: kept.categories,
                           start: kept.start, end: kept.end, userEdited: true)
        // A trip the user edited keeps the user's own mark.
        let ours = [[true, interaction != .userEdited]]
        #expect(try keptRow(id, container) == held, "after the unit")
        #expect(try marks(id, container) == ours, "after the unit")

        await ordinaryPass(classifier)
        #expect(try keptRow(id, container) == held, "after the follow-up pass")

        let late = ModelContext(container)
        stay(late, place.isReverse ? Self.ieper : Self.brussels, 13.85, 14.1)
        try late.save()
        for round in 1...5 {
            await ordinaryPass(classifier)
            #expect(try keptRow(id, container) == held, "after pass \(round)")
        }
        #expect(try marks(id, container) == ours, "after the passes")
    }

    @Test("removing a temporary home frees a stay just after an open favorite: the favorite is marked and keeps its id, and the larger completed trip beyond the freed stay keeps its own")
    func openFavoriteBeforeAFreedStayKeepsItsIDBesideALargerNeighbour() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        let row = temporaryHome(ctx, from: 10, until: nil)
        let favoriteStay = stay(ctx, Self.ieper, 10.2, 10.8, .destination)
        stay(ctx, Self.brussels, 11.2, 12.8, .home, by: row.id)
        let neighbour = [stay(ctx, Self.bedburg, 13.2, 13.8, .destination),
                         stay(ctx, Self.bedburg, 14.2, 14.8, .destination),
                         stay(ctx, Self.bedburg, 15.2, 15.8, .destination)]
        stay(ctx, Self.athens, 20.2, 25, .home)
        // As an import or a sync can leave them: the favorite still open.
        let favorite = trip(ctx, [favoriteStay])
        favorite.isComplete = false
        favorite.endDate = nil
        let favoriteID = favorite.id
        let neighbourID = trip(ctx, neighbour).id
        try ctx.save()
        try markRemoved(row, ctx, on: 30)

        let classifier = await makeClassifier(container)
        #expect(await reconcile(classifier, row.id, pinned: [favoriteID])
                == .committed(stamped: 0, freed: 1, rebuiltTrips: 0, protectedTrips: 1))
        #expect(try marks(favoriteID, container) == [[true, true]])

        await ordinaryPass(classifier)
        let all = try trips(container)
        #expect(all.filter { $0.id == favoriteID }.count == 1)
        #expect(all.first { $0.id == favoriteID }?.stays.contains(favoriteStay.id) == true)
        // The favorite closed at the Athens return, so the freed Brussels stay,
        // with no home between it and Bedburg, joins the trip beyond it; that
        // trip keeps its id and every stay it had.
        let neighbourAfter = all.filter { $0.id == neighbourID }
        #expect(neighbourAfter.count == 1)
        #expect(neighbourAfter.first?.stays.isSuperset(of: Set(neighbour.map(\.id))) == true)
        #expect(try marks(favoriteID, container) == [[true, true]])
    }

    @Test("assembly that makes a trip hold a stay the user set makes it the user's own edit: a temporary home's mark on the row it reuses goes")
    func assemblyClearsTheMarkForAnOverriddenStay() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        let chosen = stay(ctx, Self.vienna, 10.2, 12.8, .destination)
        chosen.userOverridden = true
        let open = trip(ctx, [chosen])
        open.isComplete = false
        open.endDate = nil
        open.keptByTemporaryHome = true
        // A new stay, so the pass assembles.
        stay(ctx, Self.vienna, 13.2, 13.8)
        try ctx.save()

        await ordinaryPass(await makeClassifier(container))
        let holding = try ModelContext(container).fetch(FetchDescriptor<Trip>())
            .filter { ($0.stays ?? []).contains { $0.id == chosen.id } }
        #expect(holding.count == 1)
        #expect(holding.first?.userEdited == true)
        #expect(holding.first?.keptByTemporaryHome == false)
    }

    @Test("with no temporary home nothing marks a trip: favorites, photo choices and names stay what they were through ordinary passes and a reconciliation of an id the store does not hold")
    func noTemporaryHomeMarksNothing() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        let pinned = trip(ctx, [stay(ctx, Self.vienna, 10.2, 12.8, .destination)])
        stay(ctx, Self.athens, 13.2, 19.8, .home)
        let annotated = trip(ctx, [stay(ctx, Self.brno, 20.2, 21.8, .destination)])
        ctx.insert(HiddenPhoto(localIdentifier: "asset-1", tripID: annotated.id))
        stay(ctx, Self.athens, 22.2, 29.8, .home)
        let named = trip(ctx, [stay(ctx, Self.vienna, 30.2, 31.8, .destination)])
        named.customName = "Vienna week"
        stay(ctx, Self.athens, 32.2, 39.8, .home)
        stay(ctx, Self.vienna, 40.2, 41.8)
        try ctx.save()
        let pinnedID = pinned.id

        let classifier = await makeClassifier(container)
        await ordinaryPass(classifier)
        #expect(await reconcile(classifier, UUID(), pinned: [pinnedID])
                == .committed(stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 0))
        await ordinaryPass(classifier)
        let all = try ModelContext(container).fetch(FetchDescriptor<Trip>())
        #expect(!all.isEmpty)
        for trip in all {
            #expect(!trip.userEdited)
            #expect(!trip.keptByTemporaryHome)
        }
    }
}

// MARK: - The journey home at the end

extension TemporaryHomeJourneyTests {
    /// About 260 km south of Brussels.
    private static let paris: Place = (48.86, 2.35)

    @Test("the last trip of a semester leaves the base and ends at the real home: it is one completed trip that starts after the last stay at the base, ends before the first stay at the real home, leaves from the base and is one of its trips, whether the temporary home was ended on the last day at the base or left open",
          arguments: [Double?.some(30.999), nil])
    func lastTripLeavesTheBaseAndEndsAtTheRealHome(endedAt end: Double?) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        let semester = temporaryHome(ctx, from: 10, until: end)
        try ctx.save()
        let classifier = await makeClassifier(container)
        _ = await reconcile(classifier, semester.id)

        let base = stay(ctx, Self.brussels, 10.2, 30.8)
        let paris = stay(ctx, Self.paris, 31.2, 33.8)
        let departure = stay(ctx, (49.01, 2.55), 34.0, 34.1, airport: true)
        let home = stay(ctx, Self.athens, 34.6, 40.8)
        try ctx.save()
        await ordinaryPass(classifier)

        try expect([base], are: .home, in: nil, container)
        try expect([home], are: .home, in: nil, container)
        let all = try trips(container)
        try #require(all.count == 1)
        #expect(all[0].stays.contains(paris.id))
        #expect(all[0].stays.isSubset(of: [paris.id, departure.id]))
        #expect(all[0].start == date(31.2))
        #expect(all[0].isComplete)
        let tripEnd = try #require(all[0].end)
        #expect(tripEnd >= date(33.8))
        #expect(tripEnd <= date(34.1))

        #expect(try TemporaryHomeCards.departurePlaceName(
            tripStart: all[0].start, container: container) == "Brussels")
        let cards = try TemporaryHomeCards.load(
            container: container, now: date(45), fallbackZone: TimeZone(identifier: "GMT")!)
        #expect(cards.first?.tripIDs == [all[0].id])
    }
}
