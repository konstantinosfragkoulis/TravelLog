//
//  TripAssemblyTests.swift
//  TravelLogTests
//
//  Stage 3 trip assembly — TripClassifier.assembleTrips() and its helpers
//  hasHomeStayBetween / closeTrip, plus the Stage 4 safety net
//  closeStaleOpenTrips(). Purely in-memory SwiftData; no AI, no network.
//
//  CORE INVARIANT under test: trip boundaries are PURELY DETERMINISTIC. A new
//  trip starts ONLY when a `.home` stay sits (by time) between two consecutive
//  trip (destination/transit) stays. The AI `continuesPreviousTrip` flag is
//  intentionally ignored. No intervening home → same trip. Always.
//
//  OBSERVABILITY (CRITICAL #2): assembleTrips() and closeStaleOpenTrips()
//  MUTATE the actor's own modelContext but do NOT call save() — the pipeline
//  caller persists afterwards (TripClassifier.classifyPendingStays, line ~303).
//  Therefore a *fresh* ModelContext refetch would NOT see the assembled trips.
//  We observe two ways:
//    1. The method RETURN VALUE (number of new trips created / stale closed) —
//       directly pins the 1-trip vs 2-trip boundary decisions.
//    2. The #if DEBUG `assembledTripsForTesting()` accessor, which reads the
//       actor's OWN (unsaved) context and returns value-type snapshots
//       (isComplete, endDate, orderInTrip list, userEdited) so we can assert
//       the in-context trip shape without crossing the actor boundary with
//       non-Sendable @Model objects.
//
//  Seeding contract: assembleTrips() fetches from its own context, so we MUST
//  `try ctx.save()` after inserting fixtures and BEFORE the awaited call — the
//  actor's context cannot see our unsaved inserts otherwise.
//
//  @MainActor because the app target is MainActor-by-default; that makes the
//  @Model types (Stay/Trip) and the @ModelActor TripClassifier touchable here.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor @Suite(IsolatedLineageDefaults())
struct TripAssemblyTests {

    // MARK: - Fixture builders

    /// Reference epoch for all timestamps. Using a fixed instant keeps the
    /// suite deterministic and parallel-safe (no global mutable state).
    private nonisolated static let day: TimeInterval = 24 * 60 * 60

    private nonisolated func date(day offset: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: 26_611_200 + offset * Self.day)
    }

    /// Insert a stay spanning [startDay, startDay + durationHours] with the
    /// given category. `userOverridden` exercises the userEdited-preservation
    /// path in assembleTrips. Nonisolated so tests can build stays inside
    /// `TripClassifier.runIsolated`.
    @discardableResult
    private nonisolated func makeStay(
        in ctx: ModelContext,
        startDay: Double,
        durationHours: Double,
        category: StayCategory,
        userOverridden: Bool = false,
        hex: String
    ) -> Stay {
        let start = date(day: startDay)
        let end = start.addingTimeInterval(durationHours * 60 * 60)
        let stay = Stay(
            startTime: start,
            endTime: end,
            centroidLatitude: 0, centroidLongitude: 0,
            h3IndexRes6: hex,
            // 2, not 1: these helpers build multi-hour stays, which in
            // production always hold at least an arrival and a later fix.
            // `isQualifyingHomeBoundary` rejects a DEFINITIVELY single-ping
            // live-SLC home stay because its dwell is synthesized by the
            // clusterer's midpoint extension rather than measured.
            pingCount: 2,
            distanceFromHomeKm: 0, pingIDs: []
        )
        stay.category = category
        stay.userOverridden = userOverridden
        ctx.insert(stay)
        return stay
    }

    private nonisolated static let fastPathHome = (lat: 37.98, lon: 23.73)
    private nonisolated static let farTail = (lat: 37.6500, lon: 24.0270)
    private nonisolated static let nearTail = (lat: 37.9364, lon: 23.9445)

    private static func fastPathSquareShape() -> HomeShape {
        HomeShape.urbanCentre(
            id: 1, name: "AthensTest", areaKm2: .pi * 11.45 * 11.45,
            rings: [[[23.68, 37.93, 23.78, 37.93, 23.78, 38.03, 23.68, 38.03]]],
            centreLatitude: fastPathHome.lat, centreLongitude: fastPathHome.lon)
    }

    @discardableResult
    private func makeHome(in ctx: ModelContext) -> Home {
        let home = Home(
            label: "Home",
            latitude: Self.fastPathHome.lat,
            longitude: Self.fastPathHome.lon,
            radiusKm: 25,
            startedAt: date(day: -30))
        ctx.insert(home)
        return home
    }

    @discardableResult
    private func makeWitnessPing(
        in ctx: ModelContext,
        at timestamp: Date,
        lat: Double,
        lon: Double,
        accuracy: Double,
        source: DataSource
    ) -> LocationPing {
        let ping = LocationPing(
            timestamp: timestamp,
            latitude: lat,
            longitude: lon,
            horizontalAccuracy: accuracy,
            h3IndexRes6: H3Service.cellIndex(latitude: lat, longitude: lon) ?? "witness",
            source: source)
        ctx.insert(ping)
        return ping
    }

    @discardableResult
    private func makeTailStay(
        in ctx: ModelContext,
        start: Date,
        lat: Double,
        lon: Double,
        pingIDs: [UUID],
        pingCount: Int,
        userOverridden: Bool = false
    ) -> Stay {
        let stay = Stay(
            startTime: start,
            endTime: start,
            centroidLatitude: lat,
            centroidLongitude: lon,
            h3IndexRes6: H3Service.cellIndex(latitude: lat, longitude: lon) ?? "tail",
            pingCount: pingCount,
            distanceFromHomeKm: 0,
            pingIDs: pingIDs)
        stay.category = .transit
        stay.userOverridden = userOverridden
        ctx.insert(stay)
        return stay
    }

    @discardableResult
    private func makeQualifyingHomeStay(
        in ctx: ModelContext,
        start: Date,
        pingCount: Int = 2
    ) -> Stay {
        let stay = Stay(
            startTime: start,
            endTime: start.addingTimeInterval(20 * 60),
            centroidLatitude: Self.fastPathHome.lat,
            centroidLongitude: Self.fastPathHome.lon,
            h3IndexRes6: H3Service.cellIndex(
                latitude: Self.fastPathHome.lat,
                longitude: Self.fastPathHome.lon) ?? "home",
            pingCount: pingCount,
            distanceFromHomeKm: 0,
            pingIDs: [])
        stay.category = .home
        ctx.insert(stay)
        return stay
    }

    private func makeFastPathFixture(
        latitude: Double = Self.farTail.lat,
        longitude: Double = Self.farTail.lon,
        newestAge: TimeInterval = 60,
        accuracy: Double = 25,
        source: DataSource = .liveSLC,
        pingCount: Int = 2,
        pingSpacing: TimeInterval = 4 * 60,
        userOverridden: Bool = false,
        includeHomeMembership: Bool = true
    ) async throws -> (
        ctx: ModelContext,
        classifier: TripClassifier,
        tail: Stay,
        pings: [LocationPing]
    ) {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        if includeHomeMembership { makeHome(in: ctx) }
        let newestAt = Date.now.addingTimeInterval(-newestAge)
        var pings: [LocationPing] = []
        for offset in (0..<pingCount).reversed() {
            pings.append(makeWitnessPing(
                in: ctx,
                at: newestAt.addingTimeInterval(-Double(offset) * pingSpacing),
                lat: latitude,
                lon: longitude,
                accuracy: accuracy,
                source: source))
        }
        let tail = makeTailStay(
            in: ctx,
            start: newestAt,
            lat: latitude,
            lon: longitude,
            pingIDs: pings.map(\.id),
            pingCount: pingCount,
            userOverridden: userOverridden)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        if includeHomeMembership {
            await classifier.primeShapeForTesting(
                latitude: Self.fastPathHome.lat,
                longitude: Self.fastPathHome.lon,
                shape: Self.fastPathSquareShape())
        }
        return (ctx, classifier, tail, pings)
    }

    // MARK: - Foreground fast path (provisional open tail)

    // Without `provisionalOpenDue()` in the back-half gate, pass 2 skips and the exact-one-incomplete-trip assertions fail.
    @Test("public pipeline opens a provisional trip after tail ping accretion")
    func publicPipelineOpensProvisionalAfterTailAccretion() async throws {
        let fixture = try await makeFastPathFixture(pingCount: 1)
        let tailID = fixture.tail.id

        #expect(await fixture.classifier.classifyAndAssembleTripsWithGates() == 0)
        #expect(await fixture.classifier.assembledTripsForTesting().isEmpty)

        let secondPing = makeWitnessPing(
            in: fixture.ctx,
            at: .now,
            lat: Self.farTail.lat,
            lon: Self.farTail.lon,
            accuracy: 25,
            source: .liveSLC)
        fixture.tail.pingIDs.append(secondPing.id)
        fixture.tail.pingCount = 2
        fixture.tail.endTime = secondPing.timestamp
        try fixture.ctx.save()

        #expect(await fixture.classifier.classifyAndAssembleTripsWithGates() == 1)
        let trips = await fixture.classifier.assembledTripsForTesting()
        #expect(trips.count == 1)
        let trip = try #require(trips.first)
        #expect(trip.isComplete == false)
        #expect(trip.hasEndDate == false)
        #expect(trip.orders == [0])

        let readContext = ModelContext(fixture.ctx.container)
        let tailDescriptor = FetchDescriptor<Stay>(
            predicate: #Predicate { $0.id == tailID })
        let persistedTail = try #require(try readContext.fetch(tailDescriptor).first)
        #expect(persistedTail.trip?.id == trip.id)
    }

    // Without `openTripClosureDue()` in the back-half gate, pass 2 skips and the empty-trip assertion fails.
    @Test("public pipeline deletes a provisional trip after home accretion")
    func publicPipelineDeletesProvisionalAfterHomeAccretion() async throws {
        let fixture = try await makeFastPathFixture()
        let home = makeQualifyingHomeStay(
            in: fixture.ctx,
            start: fixture.tail.endTime.addingTimeInterval(1),
            pingCount: 1)
        home.endTime = home.startTime
        try fixture.ctx.save()

        #expect(await fixture.classifier.classifyAndAssembleTripsWithGates() == 1)
        let openTrips = await fixture.classifier.assembledTripsForTesting()
        #expect(openTrips.count == 1)
        #expect(openTrips.first?.isComplete == false)
        #expect(openTrips.first?.hasEndDate == false)

        home.pingCount = 2
        home.endTime = home.startTime.addingTimeInterval(20 * 60)
        try fixture.ctx.save()

        #expect(await fixture.classifier.classifyAndAssembleTripsWithGates() == 0)
        #expect(await fixture.classifier.assembledTripsForTesting().isEmpty)
    }

    @Test("a fresh far live witness opens a provisional trip")
    func freshFarLiveWitnessOpensProvisionalTrip() async throws {
        let fixture = try await makeFastPathFixture()

        #expect(await fixture.classifier.assembleTrips() == 1)
        let trips = await fixture.classifier.assembledTripsForTesting()
        #expect(trips.count == 1)
        #expect(trips.first?.isComplete == false)
        #expect(trips.first?.hasEndDate == false)
    }

    @Test("a foreground-stream witness opens a provisional trip")
    func foregroundStreamWitnessOpensProvisionalTrip() async throws {
        let fixture = try await makeFastPathFixture(source: .foregroundStream)

        #expect(await fixture.classifier.assembleTrips() == 1)
        let trips = await fixture.classifier.assembledTripsForTesting()
        #expect(trips.count == 1)
        #expect(trips.first?.isComplete == false)
        #expect(trips.first?.hasEndDate == false)
    }

    @Test("a single-ping tail does not open")
    func singlePingTailDoesNotOpen() async throws {
        let fixture = try await makeFastPathFixture(pingCount: 1)
        #expect(await fixture.classifier.assembleTrips() == 0)
        #expect(await fixture.classifier.assembledTripsForTesting().isEmpty)
    }

    @Test("a stale witness does not open")
    func staleWitnessDoesNotOpen() async throws {
        let fixture = try await makeFastPathFixture(newestAge: 16 * 60)
        #expect(await fixture.classifier.assembleTrips() == 0)
    }

    @Test("an inaccurate witness does not open")
    func inaccurateWitnessDoesNotOpen() async throws {
        let fixture = try await makeFastPathFixture(accuracy: 1_500)
        #expect(await fixture.classifier.assembleTrips() == 0)
    }

    @Test("a photo-import witness does not open")
    func photoImportWitnessDoesNotOpen() async throws {
        let fixture = try await makeFastPathFixture(source: .photoImport)
        #expect(await fixture.classifier.assembleTrips() == 0)
    }

    @Test("a near-home tail does not open")
    func nearTailDoesNotOpen() async throws {
        let fixture = try await makeFastPathFixture(
            latitude: Self.nearTail.lat,
            longitude: Self.nearTail.lon)
        #expect(await fixture.classifier.assembleTrips() == 0)
    }

    @Test("a tail inside home membership does not open")
    func insideMembershipTailDoesNotOpen() async throws {
        let fixture = try await makeFastPathFixture(
            latitude: Self.fastPathHome.lat,
            longitude: Self.fastPathHome.lon)
        #expect(await fixture.classifier.assembleTrips() == 0)
    }

    @Test("far opening stays admitted as witness count increases")
    func farOpeningIsMonotoneAcrossWitnessCounts() async throws {
        for pingCount in [2, 3, 5] {
            let fixture = try await makeFastPathFixture(pingCount: pingCount)
            #expect(await fixture.classifier.assembleTrips() == 1)
        }
    }

    @Test("far opening stays monotone across thinning masks")
    func farOpeningIsMonotoneAcrossThinningMasks() async throws {
        let masks: [(name: String, indices: [Int], shouldOpen: Bool)] = [
            ("all", [0, 1, 2, 3, 4], true),
            ("first+last only", [0, 4], true),
            ("one ping (newest)", [4], false),
            ("outage window (drop middle three)", [0, 4], true),
        ]

        for mask in masks {
            let fixture = try await makeFastPathFixture(
                pingCount: 5, pingSpacing: 2 * 60)
            let keptPings = mask.indices.map { fixture.pings[$0] }
            fixture.tail.pingIDs = keptPings.map(\.id)
            fixture.tail.pingCount = keptPings.count
            try fixture.ctx.save()

            let created = await fixture.classifier.assembleTrips()
            #expect(
                created == (mask.shouldOpen ? 1 : 0),
                Comment(rawValue: mask.name))
        }
    }

    @Test("a user-overridden tail never opens")
    func userOverriddenTailNeverOpens() async throws {
        let fixture = try await makeFastPathFixture(userOverridden: true)
        #expect(await fixture.classifier.assembleTrips() == 0)
    }

    @Test("a tail without home membership does not open")
    func noHomeMembershipDoesNotOpen() async throws {
        let fixture = try await makeFastPathFixture(includeHomeMembership: false)
        #expect(await fixture.classifier.assembleTrips() == 0)
    }

    @Test("a qualifying home boundary closes the tail before it can open")
    func closedTailDoesNotOpen() async throws {
        let fixture = try await makeFastPathFixture()
        makeQualifyingHomeStay(
            in: fixture.ctx,
            start: fixture.tail.endTime.addingTimeInterval(1))
        try fixture.ctx.save()
        #expect(await fixture.classifier.assembleTrips() == 0)
    }

    @Test("an existing provisional row keeps its identity after the witness expires")
    func retainedRowKeepsIdentityAfterWitnessExpires() async throws {
        let fixture = try await makeFastPathFixture()
        #expect(await fixture.classifier.assembleTrips() == 1)
        let originalID = try #require(
            await fixture.classifier.assembledTripsForTesting().first?.id)

        for (index, ping) in fixture.pings.enumerated() {
            ping.timestamp = Date.now.addingTimeInterval(-3600 - Double(index))
        }
        try fixture.ctx.save()

        #expect(await fixture.classifier.assembleTrips() == 1)
        let trips = await fixture.classifier.assembledTripsForTesting()
        #expect(trips.count == 1)
        #expect(trips.first?.id == originalID)
        #expect(trips.first?.isComplete == false)
    }

    @Test("a deletion-only pass reports that the pipeline changed")
    func deletionOnlyPassMarksChanges() async throws {
        let fixture = try await makeFastPathFixture()
        #expect(await fixture.classifier.assembleTrips() == 1)
        makeQualifyingHomeStay(
            in: fixture.ctx,
            start: fixture.tail.endTime.addingTimeInterval(1))
        try fixture.ctx.save()

        #expect(await fixture.classifier.assembleTrips() == 0)
        #expect(await fixture.classifier.assembledTripsForTesting().isEmpty)
        #expect(await fixture.classifier.lastPipelineMadeChangesForTesting == true)
    }

    @Test("a provisional row is not recycled for the next journey")
    func provisionalRowIsNotRecycledForNextJourney() async throws {
        let fixture = try await makeFastPathFixture()
        #expect(await fixture.classifier.assembleTrips() == 1)
        let provisionalID = try #require(
            await fixture.classifier.assembledTripsForTesting().first?.id)

        let home = makeQualifyingHomeStay(
            in: fixture.ctx,
            start: fixture.tail.endTime.addingTimeInterval(1))
        let destinationStart = home.endTime.addingTimeInterval(1)
        let destination = Stay(
            startTime: destinationStart,
            endTime: destinationStart.addingTimeInterval(6 * 3600),
            centroidLatitude: Self.farTail.lat,
            centroidLongitude: Self.farTail.lon,
            h3IndexRes6: H3Service.cellIndex(
                latitude: Self.farTail.lat,
                longitude: Self.farTail.lon) ?? "destination",
            pingCount: 2,
            distanceFromHomeKm: 0,
            pingIDs: [])
        destination.category = .destination
        fixture.ctx.insert(destination)
        try fixture.ctx.save()

        #expect(await fixture.classifier.assembleTrips() == 1)
        let trips = await fixture.classifier.assembledTripsForTesting()
        #expect(trips.count == 1)
        #expect(trips.first?.id != provisionalID)
        #expect(trips.first?.isComplete == false)
    }

    @Test("Stage 1 home classification refreshes the same-pass trip summary")
    func stageOneHomeClassificationRefreshesTripSummary() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)
        let home = makeHome(in: ctx)
        home.locality = "Palaió Fáliro"

        let athens = makeStay(
            in: ctx, startDay: 0, durationHours: 24,
            category: .destination, userOverridden: true, hex: "ATH")
        athens.metroName = "Athens"
        let aegina = makeStay(
            in: ctx, startDay: 2, durationHours: 24,
            category: .destination, userOverridden: true, hex: "AEG")
        aegina.islandName = "Aegina"
        let returnHome = makeStay(
            in: ctx, startDay: 4, durationHours: 6,
            category: .unclassified, hex: "HOME")
        returnHome.centroidLatitude = Self.fastPathHome.lat
        returnHome.centroidLongitude = Self.fastPathHome.lon
        returnHome.h3IndexRes6 = H3Service.cellIndex(
            latitude: Self.fastPathHome.lat,
            longitude: Self.fastPathHome.lon) ?? "home"
        returnHome.metroName = "Athens"
        try ctx.save()

        await classifier.primeShapeForTesting(
            latitude: Self.fastPathHome.lat,
            longitude: Self.fastPathHome.lon,
            shape: Self.fastPathSquareShape())
        _ = try TripTitleStore.homePlaceNames(
            tripStart: athens.startTime, tripEnd: returnHome.endTime, in: ctx)

        #expect(await classifier.classifyAndAssembleTripsWithGates(
            reclassifyRecentStays: false, maxStaysPerCall: nil) == 1)

        let readContext = ModelContext(container)
        let trip = try #require(try readContext.fetch(FetchDescriptor<Trip>()).first)
        #expect(trip.destinationSummary == "Aegina")
    }

    // MARK: - Core invariant: NO intervening home → ONE trip

    @Test("two consecutive destination stays with NO home between them form a single trip")
    func consecutiveDestinationsNoHomeIsOneTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // A (dest, day 0) → B (dest, day 2). No home anywhere.
        makeStay(in: ctx, startDay: 0, durationHours: 6, category: .destination, hex: "A")
        makeStay(in: ctx, startDay: 2, durationHours: 6, category: .destination, hex: "B")
        try ctx.save()

        let created = await classifier.assembleTrips()
        #expect(created == 1) // no intervening home → one trip

        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.count == 1)
        // both stays landed in the one trip, ordered 0,1
        let orders01: [Int?] = [0, 1]
        #expect(trips.first?.orders == orders01)
        // no home after the last stay → trip remains open
        #expect(trips.first?.isComplete == false)
        #expect(trips.first?.hasEndDate == false)
    }

    @Test("an all-transit home-bounded group never materializes a trip (ghost-trip fix)")
    func allTransitGroupCreatesNoTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // home → 2 h airport pickup (sanity-flipped to .transit) → home:
        // pre-fix this minted a permanent destination-less "Trip" with no
        // title and no flags — completed trips are
        // never revisited, so it survived forever.
        makeStay(in: ctx, startDay: 0, durationHours: 6, category: .home, hex: "H")
        let pickup = makeStay(in: ctx, startDay: 1, durationHours: 2, category: .transit, hex: "APT")
        makeStay(in: ctx, startDay: 2, durationHours: 6, category: .home, hex: "H")
        // A real journey elsewhere proves mixed groups still materialize
        // (its transit stay rides along as before).
        makeStay(in: ctx, startDay: 5, durationHours: 3, category: .transit, hex: "T")
        makeStay(in: ctx, startDay: 6, durationHours: 24, category: .destination, hex: "D")
        try ctx.save()

        let created = await classifier.assembleTrips()
        #expect(created == 1)

        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.count == 1)
        // The pickup stay keeps its transit semantics but belongs to no trip…
        #expect(await classifier.stayCategoryForTesting(pickup.id) == .transit)
        let tripID = try #require(trips.first?.id)
        #expect(await classifier.tripStayIDsForTesting(tripID)?.contains(pickup.id) == false)
    }

    @Test("dirty-gate: tripless pure-transit residue is steady state; an unassigned destination still trips it")
    func dirtyGateToleratesOrphanTransitOnly() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // Saved steady state after the ghost-trip fix: one orphan transit
        // stay (the skipped errand group), all destinations assigned.
        makeStay(in: ctx, startDay: 1, durationHours: 2, category: .transit, hex: "APT")
        let dest = makeStay(in: ctx, startDay: 6, durationHours: 24, category: .destination, hex: "D")
        let trip = Trip(startDate: dest.startTime)
        ctx.insert(trip)
        dest.trip = trip
        dest.orderInTrip = 0
        try ctx.save()

        // Pre-fix, the orphan transit stay alone re-armed the back half on
        // EVERY pass; now only real residue (unassigned destinations,
        // misattached home/routine) counts.
        #expect(await classifier.assemblyInvariantViolatedForTesting() == false)

        dest.trip = nil
        try ctx.save()
        #expect(await classifier.assemblyInvariantViolatedForTesting() == true)
    }

    @Test("destination then transit with no intervening home is still one trip")
    func destinationThenTransitNoHomeIsOneTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        makeStay(in: ctx, startDay: 0, durationHours: 4, category: .destination, hex: "D")
        makeStay(in: ctx, startDay: 1, durationHours: 2, category: .transit, hex: "T")
        try ctx.save()

        let created = await classifier.assembleTrips()
        #expect(created == 1)

        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.count == 1)
        let orders01: [Int?] = [0, 1]
        #expect(trips.first?.orders == orders01)
    }

    // MARK: - Core invariant: intervening home → TWO trips

    @Test("a .home stay between two destination stays splits them into two trips")
    func homeBetweenDestinationsSplitsIntoTwoTrips() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // A (dest, day 0..0.25) → H (home, day 1..1.25) → B (dest, day 2..2.25)
        // The home stay's start (day 1) falls strictly inside A.end..B.start,
        // so hasHomeStayBetween(A, B) is true → new trip starts at B.
        makeStay(in: ctx, startDay: 0, durationHours: 6, category: .destination, hex: "A")
        makeStay(in: ctx, startDay: 1, durationHours: 6, category: .home, hex: "H")
        makeStay(in: ctx, startDay: 2, durationHours: 6, category: .destination, hex: "B")
        try ctx.save()

        let created = await classifier.assembleTrips()
        #expect(created == 2) // home between A and B → exactly two trips

        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.count == 2)
        // Each trip holds one destination stay, ordered from 0.
        let single: [Int?] = [0]
        #expect(trips[0].orders == single)
        #expect(trips[1].orders == single)
    }

    @Test("home stay only counts when it falls BETWEEN the two trip stays (after the gap → no split)")
    func homeOutsideGapDoesNotSplit() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // A (dest, day 0) → B (dest, day 1) → H (home, day 5, AFTER both).
        // The home is not between A and B, so they stay in one trip; but H is
        // after the trip's last stay, so closeTrip marks the trip complete.
        makeStay(in: ctx, startDay: 0, durationHours: 6, category: .destination, hex: "A")
        makeStay(in: ctx, startDay: 1, durationHours: 6, category: .destination, hex: "B")
        makeStay(in: ctx, startDay: 5, durationHours: 6, category: .home, hex: "H")
        try ctx.save()

        let created = await classifier.assembleTrips()
        #expect(created == 1) // home is not BETWEEN A and B → single trip

        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.count == 1)
        let orders01: [Int?] = [0, 1]
        #expect(trips.first?.orders == orders01)
    }

    // MARK: - hasHomeStayBetween — direct helper coverage

    @Test("hasHomeStayBetween returns false when the after-stay does not precede the before-stay")
    func hasHomeStayBetweenRequiresOrdering() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let classifier = TripClassifier(modelContainer: container)
        try await classifier.runIsolated { classifier in
            let ctx = ModelContext(container)

            // `later` ends AFTER `earlier` starts → ordering guard fails → false,
            // regardless of any home stay.
            let earlier = makeStay(in: ctx, startDay: 5, durationHours: 6, category: .destination, hex: "E")
            let later = makeStay(in: ctx, startDay: 0, durationHours: 6, category: .destination, hex: "L")
            let home = makeStay(in: ctx, startDay: 2, durationHours: 6, category: .home, hex: "H")
            try ctx.save()

            // afterStay = earlier (day 5), beforeStay = later (day 0): earlier.end > later.start
            let result = classifier.hasHomeStayBetween(
                afterStay: earlier, beforeStay: later, allStays: [earlier, later, home]
            )
            #expect(result == false)
        }
    }

    @Test("hasHomeStayBetween is true exactly when a home stay falls inside the time gap")
    func hasHomeStayBetweenDetectsHomeInGap() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let classifier = TripClassifier(modelContainer: container)
        try await classifier.runIsolated { classifier in
            let ctx = ModelContext(container)

            let a = makeStay(in: ctx, startDay: 0, durationHours: 6, category: .destination, hex: "A")
            let b = makeStay(in: ctx, startDay: 4, durationHours: 6, category: .destination, hex: "B")
            let homeInside = makeStay(in: ctx, startDay: 2, durationHours: 6, category: .home, hex: "HI")
            let homeOutside = makeStay(in: ctx, startDay: 10, durationHours: 6, category: .home, hex: "HO")
            try ctx.save()

            let withHomeInGap = classifier.hasHomeStayBetween(
                afterStay: a, beforeStay: b, allStays: [a, b, homeInside]
            )
            #expect(withHomeInGap == true)

            let withHomeOutsideGap = classifier.hasHomeStayBetween(
                afterStay: a, beforeStay: b, allStays: [a, b, homeOutside]
            )
            #expect(withHomeOutsideGap == false)
        }
    }

    // MARK: - orderInTrip assignment 0..n

    @Test("orderInTrip is assigned 0..n in start-time order within one trip")
    func orderInTripIsZeroToNInTimeOrder() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // Four trip stays, inserted out of chronological order. assembleTrips
        // fetches sorted by startTime, so orderInTrip must follow time order.
        makeStay(in: ctx, startDay: 3, durationHours: 2, category: .destination, hex: "S3")
        makeStay(in: ctx, startDay: 0, durationHours: 2, category: .destination, hex: "S0")
        makeStay(in: ctx, startDay: 2, durationHours: 2, category: .transit, hex: "S2")
        makeStay(in: ctx, startDay: 1, durationHours: 2, category: .destination, hex: "S1")
        try ctx.save()

        let created = await classifier.assembleTrips()
        #expect(created == 1)

        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.count == 1)
        // Contiguous 0,1,2,3 with no gaps or duplicates.
        let expectedOrders: [Int?] = [0, 1, 2, 3]
        let actualOrders = trips.first?.orders
        #expect(actualOrders == expectedOrders)
    }

    // MARK: - closeTrip — sets isComplete + endDate

    @Test("closeTrip sets isComplete and endDate when a home stay follows the trip")
    func closeTripSetsCompletionAndEndDate() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // A (dest, day 0..0.25) → B (dest, day 1..1.25) → H (home, day 3).
        // No home between A and B (one trip); H is after B → closeTrip closes it.
        makeStay(in: ctx, startDay: 0, durationHours: 6, category: .destination, hex: "A")
        let b = makeStay(in: ctx, startDay: 1, durationHours: 6, category: .destination, hex: "B")
        makeStay(in: ctx, startDay: 3, durationHours: 6, category: .home, hex: "H")
        try ctx.save()
        let expectedEnd = b.endTime

        let created = await classifier.assembleTrips()
        #expect(created == 1)

        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.count == 1)
        let trip = try #require(trips.first)
        #expect(trip.isComplete == true)
        #expect(trip.hasEndDate == true)
        // endDate equals the last stay's endTime.
        #expect(trip.endDate == expectedEnd)
    }

    @Test("a trip with no following home stay stays open (isComplete == false, no endDate)")
    func tripWithNoFollowingHomeStaysOpen() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // Single destination, no home anywhere → ongoing trip.
        makeStay(in: ctx, startDay: 0, durationHours: 6, category: .destination, hex: "ONLY")
        try ctx.save()

        let created = await classifier.assembleTrips()
        #expect(created == 1)

        let trips = await classifier.assembledTripsForTesting()
        let trip = try #require(trips.first)
        #expect(trip.isComplete == false)
        #expect(trip.hasEndDate == false)
        #expect(trip.endDate == nil)
    }

    // MARK: - closeStaleOpenTrips — Stage 4 safety net

    @Test("closeStaleOpenTrips closes an open trip once a home stay follows its last stay")
    func closeStaleOpenTripsClosesAStaleTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // Build an open trip first (dest A, B; no home yet → stays open).
        makeStay(in: ctx, startDay: 0, durationHours: 6, category: .destination, hex: "A")
        let b = makeStay(in: ctx, startDay: 1, durationHours: 6, category: .destination, hex: "B")
        try ctx.save()

        let created = await classifier.assembleTrips()
        #expect(created == 1)

        // Sanity: the trip is open before we add the late home stay.
        let before = await classifier.assembledTripsForTesting()
        #expect(before.first?.isComplete == false)

        // Now the user returns home: insert a home stay AFTER the trip's last
        // stay (day 5). Save it so the actor context (which already holds the
        // unsaved trip) re-fetches a consistent home set.
        makeStay(in: ctx, startDay: 5, durationHours: 6, category: .home, hex: "H")
        try ctx.save()
        let expectedEnd = b.endTime

        let closed = await classifier.closeStaleOpenTrips()
        #expect(closed == 1) // the stale open trip is now closed

        let after = await classifier.assembledTripsForTesting()
        let trip = try #require(after.first)
        #expect(trip.isComplete == true)
        #expect(trip.hasEndDate == true)
        #expect(trip.endDate == expectedEnd)
    }

    @Test("closeStaleOpenTrips returns 0 when there is no home stay after the open trip")
    func closeStaleOpenTripsNoHomeReturnsZero() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        makeStay(in: ctx, startDay: 0, durationHours: 6, category: .destination, hex: "A")
        makeStay(in: ctx, startDay: 1, durationHours: 6, category: .destination, hex: "B")
        try ctx.save()

        let created = await classifier.assembleTrips()
        #expect(created == 1)

        // No home stay exists at all → guard returns 0, trip stays open.
        let closed = await classifier.closeStaleOpenTrips()
        #expect(closed == 0)

        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.first?.isComplete == false)
    }

    @Test("closeStaleOpenTrips leaves already-complete trips untouched (only open trips are scanned)")
    func closeStaleOpenTripsIgnoresCompleteTrips() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // A (dest) → H (home after) → closeTrip completes the trip during
        // assembly. A subsequent closeStaleOpenTrips finds no OPEN trips.
        makeStay(in: ctx, startDay: 0, durationHours: 6, category: .destination, hex: "A")
        makeStay(in: ctx, startDay: 3, durationHours: 6, category: .home, hex: "H")
        try ctx.save()

        let created = await classifier.assembleTrips()
        #expect(created == 1)

        let closed = await classifier.closeStaleOpenTrips()
        #expect(closed == 0) // the only trip was already complete

        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.first?.isComplete == true)
    }

    // MARK: - AI title carry-forward on open trips (July-2026)

    @Test("rebuilding an open trip carries the AI title forward")
    func assembleCarriesTitleOnRebuild() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // An OPEN trip (no home stay anywhere) holding an AI title.
        let s0 = makeStay(in: ctx, startDay: 0, durationHours: 6, category: .destination, hex: "A")
        let s1 = makeStay(in: ctx, startDay: 2, durationHours: 6, category: .destination, hex: "B")
        let trip = Trip(startDate: date(day: 0))
        trip.aiGeneratedTitle = "Athens & Cephalonia"
        ctx.insert(trip)
        ctx.insert(TripTitleVariant(
            languageTag: "el",
            title: "Αθήνα και Κεφαλονιά",
            sourceTitle: "Athens & Cephalonia",
            trip: trip))
        s0.trip = trip; s0.orderInTrip = 0
        s1.trip = trip; s1.orderInTrip = 1
        try ctx.save()

        // Phase 1 deletes the open trip; Phase 3 rebuilds it from the SAME
        // stay set → the carry-forward key matches exactly.
        _ = await classifier.assembleTrips()

        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.count == 1)
        let rebuiltID = try #require(trips.first?.id)
        let fields = try #require(await classifier.aiTitleFieldsForTesting(rebuiltID))
        #expect(fields.title == "Athens & Cephalonia") // carried — Stage 5 skips the FM call
        let rebuiltTrip = try #require(try ctx.fetch(FetchDescriptor<Trip>()).first)
        #expect(rebuiltTrip.displayName(languageTag: "el") == "Αθήνα και Κεφαλονιά")
    }

    @Test("closeStaleOpenTrips invalidates mid-trip AI artifacts when it closes the trip")
    func closeStaleInvalidatesMidTripTitle() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // Pre-existing open trip with attached stay + a home stay after it
        // (built by hand, NOT via assembleTrips, so the mid-trip title is
        // still present when Stage 4 closes the trip).
        let s = makeStay(in: ctx, startDay: 0, durationHours: 6, category: .destination, hex: "D")
        makeStay(in: ctx, startDay: 2, durationHours: 10, category: .home, hex: "H")
        let trip = Trip(startDate: date(day: 0))
        trip.aiGeneratedTitle = "Athens"
        ctx.insert(trip)
        ctx.insert(TripTitleVariant(
            languageTag: "el", title: "Αθήνα",
            sourceTitle: "Athens", trip: trip))
        s.trip = trip; s.orderInTrip = 0
        try ctx.save()

        let closed = await classifier.closeStaleOpenTrips()
        #expect(closed == 1)

        let fields = try #require(await classifier.aiTitleFieldsForTesting(trip.id))
        #expect(fields.title == nil)
        #expect(fields.localizedCount == 0)
    }

    // MARK: - User-overridden categories preserved (userEdited propagation)

    @Test("a trip containing a user-overridden stay is marked userEdited")
    func userOverriddenStayMarksTripUserEdited() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // One trip whose second stay is a user override.
        makeStay(in: ctx, startDay: 0, durationHours: 6, category: .destination, hex: "A")
        makeStay(in: ctx, startDay: 1, durationHours: 6, category: .destination,
                 userOverridden: true, hex: "B")
        try ctx.save()

        let created = await classifier.assembleTrips()
        #expect(created == 1)

        let trips = await classifier.assembledTripsForTesting()
        let trip = try #require(trips.first)
        #expect(trip.userEdited == true) // override on a constituent stay propagates
    }

    @Test("a trip with no user-overridden stays is NOT marked userEdited")
    func noOverrideLeavesTripNotUserEdited() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        makeStay(in: ctx, startDay: 0, durationHours: 6, category: .destination, hex: "A")
        makeStay(in: ctx, startDay: 1, durationHours: 6, category: .destination, hex: "B")
        try ctx.save()

        let created = await classifier.assembleTrips()
        #expect(created == 1)

        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.first?.userEdited == false)
    }

    @Test("user-edited (userEdited == true) trips are NOT torn down and rebuilt by assembleTrips")
    func userEditedTripIsPreserved() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // Pre-existing user-edited, still-open trip with its own stay already
        // assigned (orderInTrip 0). assembleTrips() deletes only
        // (isComplete == false && userEdited == false) trips, so this survives;
        // its stay already has trip != nil so it is NOT in `unassignedStays`.
        let edited = Trip(startDate: date(day: 0))
        edited.userEdited = true
        edited.isComplete = false
        ctx.insert(edited)

        let s = makeStay(in: ctx, startDay: 0, durationHours: 6, category: .destination, hex: "EDIT")
        s.trip = edited
        s.orderInTrip = 0

        // A separate, brand-new unassigned destination stay AFTER a home gap,
        // so assembleTrips has something fresh to build.
        makeStay(in: ctx, startDay: 5, durationHours: 6, category: .home, hex: "H")
        makeStay(in: ctx, startDay: 8, durationHours: 6, category: .destination, hex: "NEW")
        try ctx.save()

        // Only the NEW stay is unassigned → exactly one new trip is created;
        // the user-edited trip is left intact (not deleted, not rebuilt).
        let created = await classifier.assembleTrips()
        #expect(created == 1)

        let trips = await classifier.assembledTripsForTesting()
        // Two trips total: the preserved user-edited one + the newly built one.
        #expect(trips.count == 2)
        // The preserved trip retains its userEdited flag and its single stay.
        let preserved = try #require(trips.first { $0.id == edited.id })
        #expect(preserved.userEdited == true)
        let single: [Int?] = [0]
        #expect(preserved.orders == single)
    }
}
