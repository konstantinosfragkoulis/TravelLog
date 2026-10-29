//
//  TemporaryHomeAfterEndTests.swift
//  TravelLogTests
//
//  The confidence gate around a temporary home's dates, on small hand-built
//  stores through the real ordinary pass: a stay at the base after the end (or
//  before the start) is an ordinary place, a run no home existed throughout is
//  no errand, and the suppression memo hears of the inputs it does not
//  fingerprint. Fixture time is whole days from midnight UTC on 2 April
//  2001, every stay in the GMT zone, as in `TemporaryHomeJourneyTests`.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Temporary home after its end", IsolatedTitleDefaults())
struct TemporaryHomeAfterEndTests {

    private typealias Place = (lat: Double, lon: Double)
    private static let athens: Place = (38.0, 23.8)
    /// About 1.1 km north of the Athens square's edge.
    private static let athensNorth: Place = (38.06, 23.8)
    private static let brussels: Place = (50.8940, 4.2822)
    /// About 1.1 km north of the Brussels square's edge.
    private static let suburb: Place = (50.9540, 4.2821)
    /// About 110 m inside the Brussels square's northern edge, at 50.9440.
    private static let insideNorthEdge: Place = (50.9430, 4.2822)
    /// About 177 km north of Brussels.
    private static let amsterdam: Place = (52.4385, 4.8712)
    /// Outside the Brussels urban centre.
    private static let airport: Place = (50.90, 4.48)
    private static let vienna: Place = (48.21, 16.37)
    /// About 6 km east of the Athens square, inside the real home's 25 km circle.
    private static let village: Place = (38.0394, 23.9229)
    /// About 1.1 km south of the village's square.
    private static let villageSouth: Place = (37.9794, 23.9229)

    /// Fixture day 0 is 91 days after the shared fixture's day 0.
    private func date(_ day: Double) -> Date { TemporaryHomeFixture.date(day + 91) }

    /// The `TravelDays` labels of whole fixture days.
    private func labels(_ days: [ClosedRange<Int>]) -> Set<Date> {
        Set(days.flatMap { $0 }.map { date(Double($0)) })
    }

    /// A live stay from fixture day `from` to `to`. A home stay at the base
    /// names its temporary home as `owner`, as the pre-filter stamps it.
    @discardableResult
    private func stay(
        _ ctx: ModelContext, _ place: Place, _ from: Double, _ to: Double,
        _ category: StayCategory = .unclassified, airport: Bool = false, owner: UUID? = nil
    ) -> Stay {
        TemporaryHomeFixture.stay(
            ctx, place, from: date(from), to: date(to), category, hex: "J", pingCount: 2,
            zone: "GMT", airport: airport, idOnlyStamp: owner)
    }

    /// The real home in Athens since long before the fixture.
    private func seedAthens(_ ctx: ModelContext) {
        TemporaryHomeFixture.realHome(ctx, "Athens", at: Self.athens).startedAt = date(-1000)
    }

    private func temporaryHome(
        _ ctx: ModelContext, _ label: String = "Brussels", at chosen: Place? = nil,
        from: Double, until: Double?
    ) -> TemporaryHome {
        TemporaryHomeFixture.temporaryHome(
            ctx, label, at: chosen ?? Self.brussels,
            from: from + 91, until: until.map { $0 + 91 }, zone: nil)
    }

    private func makeClassifier(
        _ container: ModelContainer, also extra: [(id: Int64, place: Place)] = []
    ) async -> TripClassifier {
        await TemporaryHomeFixture.classifier(
            container, squares: [(1, Self.athens), (2, Self.brussels), (3, Self.vienna)] + extra)
    }

    /// One ordinary pipeline pass.
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

    // MARK: - The base after the end

    @Test("an errand near the base just before the end does not keep the stay at the base after the end out of a trip: one trip holds both, and the stay at the base inside the dates stays home")
    func errandBeforeTheEndDoesNotKeepTheBaseOutOfATrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let row = temporaryHome(ctx, from: 1, until: 10)
        let before = stay(ctx, Self.brussels, 9.2, 9.7, .home, owner: row.id)
        let errand = stay(ctx, Self.suburb, 9.8, 9.95, .destination)
        let after = stay(ctx, Self.brussels, 10.1, 13.8, .destination)
        let back = stay(ctx, Self.athens, 14.2, 15, .home)
        try ctx.save()

        let classifier = await makeClassifier(container)
        await ordinaryPass(classifier)

        let all = try trips(container)
        try #require(all.count == 1)
        #expect(all[0] == TripFacts(id: all[0].id, stays: [errand.id, after.id], start: date(9.8),
                                    end: date(13.8), isComplete: true, days: 5))
        try expect([errand, after], are: .destination, in: all[0].id, container)
        try expect([before, back], are: .home, in: nil, container)
    }

    @Test("without the errand, the stay at the base after the end is a trip of its own, as before")
    func withoutTheErrandTheStayAfterTheEndIsATrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let row = temporaryHome(ctx, from: 1, until: 10)
        let before = stay(ctx, Self.brussels, 9.2, 9.7, .home, owner: row.id)
        let after = stay(ctx, Self.brussels, 10.1, 13.8, .destination)
        stay(ctx, Self.athens, 14.2, 15, .home)
        try ctx.save()

        let classifier = await makeClassifier(container)
        await ordinaryPass(classifier)

        let all = try trips(container)
        try #require(all.count == 1)
        #expect(all[0].stays == [after.id])
        try expect([before], are: .home, in: nil, container)
    }

    @Test("ended while still there: the unit frees the stay at the base after the new end, and the ordinary pass makes one trip of it and the errand before the end; the ledger's staying days stop there and the trip's days are away")
    func endedWhileStillThereThenTheOrdinaryPass() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 9.4, .home)
        let row = temporaryHome(ctx, from: 10, until: nil)
        let base = [stay(ctx, Self.brussels, 10.2, 25.8, .home, owner: row.id),
                    stay(ctx, Self.brussels, 26.2, 38.5, .home, owner: row.id)]
        let errand = stay(ctx, Self.suburb, 38.6, 38.7, .destination)
        let after = stay(ctx, Self.brussels, 39.2, 44.8, .home, owner: row.id)
        stay(ctx, Self.athens, 46.2, 50.8, .home)
        try ctx.save()

        // The user ends it on day 39, still in the city.
        row.endedAt = date(39)
        try ctx.save()
        let classifier = await makeClassifier(container)
        #expect(await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: row.id, pinnedTripIDs: []).isSettled)
        try expect([after], are: .unclassified, in: nil, container)
        try expect(base, are: .home, in: nil, container)
        try expect([errand], are: .destination, in: nil, container)

        await ordinaryPass(classifier)
        let all = try trips(container)
        try #require(all.count == 1)
        #expect(all[0] == TripFacts(id: all[0].id, stays: [errand.id, after.id], start: date(38.6),
                                    end: date(44.8), isComplete: true, days: 7))
        try expect([errand, after], are: .destination, in: all[0].id, container)
        try expect(base, are: .home, in: nil, container)

        let utc = TimeZone(secondsFromGMT: 0)!
        let travelling = try TravelDays.labels(container: container, now: date(55), fallbackZone: utc)
        let ledger = try TemporaryHomeLedger.result(
            travelling: travelling, container: container, now: date(55), fallbackZone: utc,
            checkCancellation: {})
        #expect(ledger.travelling == labels([38...44]))
        #expect(ledger.staying == labels([10...37]))
        #expect(ledger.away == labels([10...44]))
    }

    @Test("arrived before the start: a stay at the base before the start date and an errand after it are one trip, and the stays at the base inside the dates are home")
    func arrivedBeforeTheStart() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        stay(ctx, Self.athens, 0.2, 8.9, .home)
        let row = temporaryHome(ctx, from: 10, until: 100)
        let early = stay(ctx, Self.brussels, 9.2, 9.9, .destination)
        let errand = stay(ctx, Self.suburb, 10.3, 10.4, .destination)
        let base = stay(ctx, Self.brussels, 10.6, 20, .home, owner: row.id)
        try ctx.save()

        let classifier = await makeClassifier(container)
        await ordinaryPass(classifier)

        let all = try trips(container)
        try #require(all.count == 1)
        #expect(all[0] == TripFacts(id: all[0].id, stays: [early.id, errand.id], start: date(9.2),
                                    end: date(10.4), isComplete: true, days: 2))
        try expect([base], are: .home, in: nil, container)
    }

    @Test("a side trip that spans the end date stays one trip")
    func sideTripAcrossTheEndIsNotSplit() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let row = temporaryHome(ctx, from: 1, until: 10)
        let base = stay(ctx, Self.brussels, 8, 8.9, .home, owner: row.id)
        let first = stay(ctx, Self.amsterdam, 9, 10.5, .destination)
        let second = stay(ctx, Self.amsterdam, 10.6, 11.8, .destination)
        stay(ctx, Self.athens, 14, 15, .home)
        try ctx.save()

        let classifier = await makeClassifier(container)
        await ordinaryPass(classifier)

        let all = try trips(container)
        try #require(all.count == 1)
        #expect(all[0].stays == [first.id, second.id])
        #expect(all[0].start == date(9))
        #expect(all[0].end == date(11.8))
        try expect([base], are: .home, in: nil, container)
    }

    @Test("after its end a temporary home is an ordinary place: a short outing there, just outside the real home's measured area, is still set aside by ordinary confidence")
    func shortStayNearTheRealHomeAfterTheEndIsStillSuppressed() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let row = temporaryHome(ctx, "Village", at: Self.village, from: 1, until: 10)
        stay(ctx, Self.village, 9, 9.9, .home, owner: row.id)
        let errand = stay(ctx, Self.villageSouth, 9.92, 9.96, .destination)
        let after = stay(ctx, Self.village, 10.2, 10.25, .destination)
        stay(ctx, Self.athens, 10.5, 12, .home)
        try ctx.save()

        let classifier = await makeClassifier(container, also: [(id: 4, place: Self.village)])
        await ordinaryPass(classifier)

        #expect(try trips(container).isEmpty)
        try expect([errand, after], are: .destination, in: nil, container)
        #expect(await classifier.assemblyInvariantViolated() == false)
    }

    // MARK: - A run no home existed throughout

    @Test("between two real homes' eras, a run that starts inside a temporary home's dates and ends after them is admitted although no home can score it")
    func unscoredRunAdmitsTheDestinationGroup() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let former = Home(label: "Athens", latitude: Self.athens.lat, longitude: Self.athens.lon,
                          radiusKm: 25, startedAt: date(-1000))
        former.endedAt = date(0)
        ctx.insert(former)
        ctx.insert(Home(label: "Vienna", latitude: Self.vienna.lat, longitude: Self.vienna.lon,
                        radiusKm: 25, startedAt: date(100)))
        let row = temporaryHome(ctx, from: 1, until: 10)
        stay(ctx, Self.brussels, 8, 9.3, .home, owner: row.id)
        let errand = stay(ctx, Self.suburb, 9.5, 9.6, .destination)
        let after = stay(ctx, Self.brussels, 10.5, 12.5, .destination)
        try ctx.save()

        let classifier = await makeClassifier(container)
        await ordinaryPass(classifier)

        let all = try trips(container)
        try #require(all.count == 1)
        #expect(all[0].stays == [errand.id, after.id])
    }

    @Test("an all-transit tail whose run no home existed throughout does not open a provisional trip: opening needs a scored run")
    func unscoredRunDoesNotOpenAProvisionalTail() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let now = Date.now
        let former = Home(label: "Athens", latitude: Self.athens.lat, longitude: Self.athens.lon,
                          radiusKm: 25, startedAt: now.addingTimeInterval(-1000 * 86_400))
        former.endedAt = now.addingTimeInterval(-30 * 86_400)
        ctx.insert(former)
        ctx.insert(TemporaryHome(
            label: "Brussels", latitude: Self.brussels.lat, longitude: Self.brussels.lon,
            startedAt: now.addingTimeInterval(-20 * 86_400), endedAt: now.addingTimeInterval(-90 * 60)))
        let flight = Stay(
            startTime: now.addingTimeInterval(-3 * 3600), endTime: now.addingTimeInterval(-2.5 * 3600),
            centroidLatitude: Self.airport.lat, centroidLongitude: Self.airport.lon,
            h3IndexRes6: "J", pingCount: 2, distanceFromHomeKm: 0, pingIDs: [])
        flight.category = .transit
        flight.isAirport = true
        ctx.insert(flight)
        // A fresh, accurate live witness at the base, after the end.
        let pings = [now.addingTimeInterval(-5 * 60), now.addingTimeInterval(-60)].map {
            LocationPing(timestamp: $0, latitude: Self.brussels.lat, longitude: Self.brussels.lon,
                         horizontalAccuracy: 25, h3IndexRes6: "J", source: .liveSLC)
        }
        pings.forEach { ctx.insert($0) }
        let tail = Stay(
            startTime: now.addingTimeInterval(-5 * 60), endTime: now.addingTimeInterval(-60),
            centroidLatitude: Self.brussels.lat, centroidLongitude: Self.brussels.lon,
            h3IndexRes6: "J", pingCount: 2, distanceFromHomeKm: 0, pingIDs: pings.map(\.id))
        tail.category = .transit
        ctx.insert(tail)
        try ctx.save()

        let classifier = await makeClassifier(container)
        #expect(await classifier.assembleTrips() == 0)
        #expect(await classifier.assembledTripsForTesting().isEmpty)
    }

    // MARK: - The suppression memo

    @Test("moving only an airport stop's coordinates re-arms a suppression the memo held, and the next pass admits the joined trip")
    func transitGeometryInvalidatesScopedSuppression() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let row = temporaryHome(ctx, from: 1, until: 10.5)
        stay(ctx, Self.brussels, 8, 9.3, .home, owner: row.id)
        let outing = stay(ctx, Self.suburb, 9 + 10.0 / 24, 9 + 14.0 / 24, .destination)
        let stop = stay(ctx, Self.brussels, 10 + 10.0 / 24, 10 + 11.0 / 24, .transit, airport: true)
        let nearAthens = stay(ctx, Self.athensNorth, 11 + 10.0 / 24, 11 + 14.0 / 24, .destination)
        try ctx.save()

        let classifier = await makeClassifier(container)
        await ordinaryPass(classifier)
        // The stop at the base inside its dates closes the outing's run, and
        // each half is a short errand near a home.
        #expect(try trips(container).isEmpty)
        #expect(await classifier.assemblyInvariantViolated() == false)

        // Sync corrects only the stop's coordinates: now it is outside the base.
        let synced = ModelContext(container)
        let copy = try #require(try synced.fetch(FetchDescriptor<Stay>()).first { $0.id == stop.id })
        copy.centroidLatitude = Self.suburb.lat
        copy.centroidLongitude = Self.suburb.lon
        try synced.save()
        #expect(await classifier.assemblyInvariantViolated() == true)

        await ordinaryPass(classifier)
        let all = try trips(container)
        try #require(all.count == 1)
        #expect(all[0].stays == [outing.id, stop.id, nearAthens.id])
        #expect(await classifier.assemblyInvariantViolated() == false)
    }

    // A destination's place was left out of the digest, and its fingerprint
    // excuses a move under 250 m.
    @Test("moving only a short destination's coordinates about 220 m across the base's edge, inside the fingerprint's jitter allowance, re-arms a suppression the memo held, and the next pass admits the joined trip")
    func destinationAcrossTheEdgeInvalidatesScopedSuppression() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let row = temporaryHome(ctx, from: 1, until: 10.5)
        stay(ctx, Self.brussels, 8, 9.3, .home, owner: row.id)
        let outing = stay(ctx, Self.suburb, 9 + 10.0 / 24, 9 + 14.0 / 24, .destination)
        let stop = stay(ctx, Self.insideNorthEdge, 10 + 10.0 / 24, 10 + 11.0 / 24, .destination)
        let nearAthens = stay(ctx, Self.athensNorth, 11 + 10.0 / 24, 11 + 14.0 / 24, .destination)
        try ctx.save()

        let classifier = await makeClassifier(container)
        await ordinaryPass(classifier)
        // The stop inside the base within its dates closes the outing's run,
        // and each half is a short errand near a home.
        #expect(try trips(container).isEmpty)
        #expect(await classifier.assemblyInvariantViolated() == false)

        // Sync corrects only the stop's latitude: now it is just outside the base.
        let synced = ModelContext(container)
        let copy = try #require(try synced.fetch(FetchDescriptor<Stay>()).first { $0.id == stop.id })
        copy.centroidLatitude = Self.brussels.lat + 0.051
        try synced.save()
        #expect(await classifier.assemblyInvariantViolated() == true)

        await ordinaryPass(classifier)
        let all = try trips(container)
        try #require(all.count == 1)
        #expect(all[0].stays == [outing.id, stop.id, nearAthens.id])
        #expect(await classifier.assemblyInvariantViolated() == false)
    }

    // The digest held a destination's containment in the
    // temporary areas only, so a move across a real Home's edge went unseen.
    @Test("with a temporary home in the store, moving only a short destination about 220 m across the real home's edge re-arms a suppression the memo held, and the next assembly admits the joined trip")
    func realHomeEdgeCrossingRearmsScopedSuppression() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        // Unrelated and long over: it only turns the digest on.
        _ = temporaryHome(ctx, from: -500, until: -400)
        let east = (lat: 38.0, lon: 23.94)
        let first = stay(ctx, east, 9 + 10.0 / 24, 9 + 14.0 / 24, .destination)
        let stop = stay(ctx, (lat: 38.049, lon: 23.8), 10 + 10.0 / 24, 10 + 11.0 / 24, .destination)
        let second = stay(ctx, east, 11 + 10.0 / 24, 11 + 14.0 / 24, .destination)
        try ctx.save()

        let classifier = await makeClassifier(container)
        await ordinaryPass(classifier)
        // The stop inside Athens splits two four-hour outings near home.
        #expect(try trips(container).isEmpty)
        #expect(await classifier.assemblyInvariantViolated() == false)

        let synced = ModelContext(container)
        let copy = try #require(try synced.fetch(FetchDescriptor<Stay>()).first { $0.id == stop.id })
        copy.centroidLatitude = 38.051
        try synced.save()
        #expect(await classifier.assemblyInvariantViolated() == true)

        await ordinaryPass(classifier)
        let all = try trips(container)
        try #require(all.count == 1)
        #expect(all[0].stays == [first.id, stop.id, second.id])
    }

    // The digest held a destination's exact place, so live
    // jitter the fingerprint excuses re-armed the check whenever any temporary
    // home existed.
    @Test("with an ended temporary home far from it, a suppressed outing near the real home whose centroid jitters by some 55 m and whose end grows by 30 seconds, crossing no area's edge, keeps the suppression quiet")
    func harmlessLiveJitterKeepsTheScopedSuppressionQuiet() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        _ = temporaryHome(ctx, from: -500, until: -400)
        // Two hours some 8 km east of the Athens square, as `HomeShapeGateTests` seeds one.
        let east: Place = (38.0, 23.94)
        let outing = stay(ctx, east, 0, 2.0 / 24, .destination)
        outing.distanceFromHomeKm = 10
        try ctx.save()

        let classifier = await makeClassifier(container)
        _ = await classifier.assembleTrips()
        #expect(await classifier.assemblyInvariantViolated() == false)

        outing.centroidLatitude += 0.0005
        outing.endTime = outing.endTime.addingTimeInterval(30)
        try ctx.save()
        #expect(await classifier.assemblyInvariantViolated() == false)
    }

    // The check read the corrections inside `withShapes`,
    // which turns a failed read into an empty table.
    @Test("with a temporary home in the store, a correction read that fails while the check rebuilds the digest re-arms the check instead of matching an area without them")
    func failedCorrectionReadRearmsTheScopedSuppression() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        _ = temporaryHome(ctx, from: -500, until: -400)
        let east: Place = (38.0, 23.94)
        let outing = stay(ctx, east, 0, 2.0 / 24, .destination)
        outing.distanceFromHomeKm = 10
        try ctx.save()

        let classifier = await makeClassifier(container)
        _ = await classifier.assembleTrips()
        #expect(await classifier.assemblyInvariantViolated() == false)

        classifier.failInvariantOverrideFetchForTesting = true
        #expect(await classifier.assemblyInvariantViolated() == true)
        classifier.failInvariantOverrideFetchForTesting = false
        #expect(await classifier.assemblyInvariantViolated() == false)
    }

    @Test("an end date that arrives by sync, with no reconciliation on this device, re-arms a suppression the same classifier's memo held, and the next pass admits the trip")
    func remoteEndDateChangeInvalidatesSuppression() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let row = temporaryHome(ctx, from: 1, until: 20)
        let rowID = row.id
        stay(ctx, Self.brussels, 8, 9.3, .home, owner: row.id)
        let errand = stay(ctx, Self.suburb, 9.5, 9.6, .destination)
        let base = stay(ctx, Self.brussels, 10.5, 12.5, .destination)
        stay(ctx, Self.athens, 14.2, 15, .home)
        try ctx.save()

        let classifier = await makeClassifier(container)
        await ordinaryPass(classifier)
        #expect(try trips(container).isEmpty)
        #expect(await classifier.assemblyInvariantViolated() == false)

        let synced = ModelContext(container)
        let copy = try #require(try synced.fetch(FetchDescriptor<TemporaryHome>()).first { $0.id == rowID })
        copy.endedAt = date(10)
        try synced.save()
        #expect(await classifier.assemblyInvariantViolated() == true)

        await ordinaryPass(classifier)
        let all = try trips(container)
        try #require(all.count == 1)
        #expect(all[0].stays == [errand.id, base.id])
    }

    @Test("with nothing changed, a suppression the memo holds beside a temporary home stays quiet pass after pass")
    func unchangedInputsKeepTheSuppressionQuiet() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedAthens(ctx)
        let row = temporaryHome(ctx, from: 1, until: 20)
        stay(ctx, Self.brussels, 8, 9.3, .home, owner: row.id)
        stay(ctx, Self.suburb, 9.5, 9.6, .destination)
        stay(ctx, Self.airport, 9.7, 9.75, .transit, airport: true)
        stay(ctx, Self.brussels, 10.5, 12.5, .home, owner: row.id)
        try ctx.save()

        let classifier = await makeClassifier(container)
        await ordinaryPass(classifier)
        #expect(await classifier.assemblyInvariantViolated() == false)
        await ordinaryPass(classifier)
        #expect(await classifier.assemblyInvariantViolated() == false)
        #expect(try trips(container).isEmpty)
    }
}
