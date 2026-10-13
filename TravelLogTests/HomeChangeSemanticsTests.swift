//
//  HomeChangeSemanticsTests.swift
//  TravelLogTests
//
//  Pins home-change behavior:
//
//  1. `TripClassifier.homeEffectiveStart` — the contiguous-arrival
//     backdate rule for a home registered AFTER the user got there.
//  2. `TripClassifier.applyHomeChangeCore` — registering home B mid-trip
//     backdates the home, re-stamps the arrival stays, detaches them from
//     the in-flight trip, and recomputes their `distanceFromHomeKm`; the
//     narrow pipeline seams then CLOSE the trip at the real homecoming.
//     Pre-fix, a home add/edit was a bare row write and the trip stayed
//     open until a manual Reclassify All.
//  3. `StayClusterer.closestHomeDistanceKm` — the canonical date-aware
//     distance rule, now a shared pure static.
//  4. `YearWrappedGenerator.farthestFromHome` — stored home-at-the-time
//     distances (Passport parity), sentinel-guarded, deterministic ties.
//     Pre-fix, Wrapped measured live from the CURRENT home (wrong for
//     past years after a move; nondeterministic with two active homes).
//  5. `StatsAggregator` country "home" badge — present-tense (active
//     home's country) with the stay-derived fallback.
//
//  Pattern (same as OngoingTripReuseTests): seed prior state by hand via
//  a plain context + save, then drive the actor's seams. The end-to-end
//  test uses `applyHomeChangeCore` + `preFilterStays`/`assembleTrips`/
//  `closeStaleOpenTrips` — NOT the full pipeline — so Stage 2's FM lane
//  never runs (deterministic on FM-capable dev simulators).
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
struct HomeChangeSemanticsTests {

    private static let day: TimeInterval = 24 * 60 * 60

    private func date(day offset: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: offset * Self.day)
    }

    @discardableResult
    private func makeStay(
        in ctx: ModelContext,
        startDay: Double,
        durationHours: Double = 6,
        category: StayCategory,
        latitude: Double,
        distanceFromHomeKm: Double = 0,
        hex: String = ""
    ) -> Stay {
        let start = date(day: startDay)
        let stay = Stay(
            startTime: start,
            endTime: start.addingTimeInterval(durationHours * 3600),
            centroidLatitude: latitude, centroidLongitude: 0,
            // 2, not 1: this helper builds duration-parameterised stays, and a
            // real stay of any length holds an arrival plus at least one later
            // fix. A DEFINITIVELY single-ping live-SLC home stay no longer
            // qualifies as a trip boundary, because its dwell is synthesized by
            // the clusterer's midpoint extension rather than measured. These fixtures model
            // homecomings, which must still close their trip.
            h3IndexRes6: hex, pingCount: 2,
            distanceFromHomeKm: distanceFromHomeKm, pingIDs: []
        )
        stay.category = category
        ctx.insert(stay)
        return stay
    }

    @discardableResult
    private func makeOpenTrip(in ctx: ModelContext, stays: [Stay], startDay: Double) -> Trip {
        let trip = Trip(startDate: date(day: startDay))
        ctx.insert(trip)
        for (order, stay) in stays.enumerated() {
            stay.trip = trip
            stay.orderInTrip = order
        }
        return trip
    }

    private func stayPoint(_ latitude: Double, day: Double) -> TripClassifier.StayPoint {
        TripClassifier.StayPoint(latitude: latitude, longitude: 0, startTime: date(day: day))
    }

    // MARK: - homeEffectiveStart (pure)

    @Test("effective start backdates to the contiguous trailing arrival run")
    func effectiveStartBackdates() {
        let stays = [
            stayPoint(0, day: 0),     // home A — outside B's ring
            stayPoint(1, day: 2),     // waypoint — outside
            stayPoint(2.0, day: 4),   // arrival at B
            stayPoint(2.01, day: 5),  // still at B
        ]
        let effective = TripClassifier.homeEffectiveStart(
            homeLatitude: 2, homeLongitude: 0, radiusKm: 25, stays: stays
        )
        #expect(effective == date(day: 4))
    }

    @Test("no backdate when the user is not currently at the new home")
    func effectiveStartNilWhenElsewhere() {
        let stays = [
            stayPoint(2.0, day: 0),  // old visit to B
            stayPoint(0, day: 2),    // latest stay: back at A
        ]
        let effective = TripClassifier.homeEffectiveStart(
            homeLatitude: 2, homeLongitude: 0, radiusKm: 25, stays: stays
        )
        #expect(effective == nil)
        #expect(TripClassifier.homeEffectiveStart(
            homeLatitude: 2, homeLongitude: 0, radiusKm: 25, stays: []
        ) == nil)
    }

    @Test("a historical visit does not extend the run past an away stay")
    func effectiveStartBreaksAtAwayStay() {
        let stays = [
            stayPoint(2.0, day: 0),   // tourist visit to B years before
            stayPoint(0, day: 50),    // home A — breaks the run
            stayPoint(2.0, day: 100), // the real move
            stayPoint(2.0, day: 101),
        ]
        let effective = TripClassifier.homeEffectiveStart(
            homeLatitude: 2, homeLongitude: 0, radiusKm: 25, stays: stays
        )
        #expect(effective == date(day: 100))
    }

    // MARK: - closestHomeDistanceKm (pure)

    @Test("distance uses the home active at the given time, not the current one")
    func distanceIsDateAware() {
        let homes = [
            StayClusterer.HomeWindow(latitude: 0, longitude: 0, startedAt: date(day: -100), endedAt: date(day: 10)),
            StayClusterer.HomeWindow(latitude: 2, longitude: 0, startedAt: date(day: 10), endedAt: nil),
        ]
        // A stay AT home B's coordinates while home A was active measures
        // from A (~222 km), not from the current home B.
        let duringA = StayClusterer.closestHomeDistanceKm(
            latitude: 2, longitude: 0, atTime: date(day: 5), homes: homes
        )
        #expect(abs(duringA - 222.4) < 3)
        let duringB = StayClusterer.closestHomeDistanceKm(
            latitude: 2, longitude: 0, atTime: date(day: 12), homes: homes
        )
        #expect(duringB < 1)
    }

    @Test("no homes yields the sentinel; pre-history falls back to current homes")
    func distanceEdges() {
        #expect(StayClusterer.closestHomeDistanceKm(
            latitude: 0, longitude: 0, atTime: .now, homes: []
        ) == Double.greatestFiniteMagnitude)

        let homes = [
            StayClusterer.HomeWindow(latitude: 0, longitude: 0, startedAt: date(day: 0), endedAt: nil)
        ]
        let preHistory = StayClusterer.closestHomeDistanceKm(
            latitude: 1, longitude: 0, atTime: date(day: -50), homes: homes
        )
        #expect(abs(preHistory - 111.2) < 2)
    }

    // MARK: - applyHomeChangeCore (the user's scenario, end to end)

    @Test("registering home B after arriving closes the in-flight trip at the real homecoming")
    func homeBRegistrationClosesTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let homeA = Home(label: "A", latitude: 0, longitude: 0, radiusKm: 25)
        homeA.startedAt = date(day: -100)
        ctx.insert(homeA)

        makeStay(in: ctx, startDay: 0, category: .home, latitude: 0)
        let waypoint = makeStay(in: ctx, startDay: 2, category: .destination, latitude: 1, distanceFromHomeKm: 111)
        let arrival = makeStay(in: ctx, startDay: 4, category: .destination, latitude: 2.0, distanceFromHomeKm: 222)
        let bStay2 = makeStay(in: ctx, startDay: 5, category: .destination, latitude: 2.01, distanceFromHomeKm: 223)
        let bStay3 = makeStay(in: ctx, startDay: 6, category: .destination, latitude: 2.0, distanceFromHomeKm: 222)
        makeOpenTrip(in: ctx, stays: [waypoint, arrival, bStay2, bStay3], startDay: 2)

        // Settings "Add Home" semantics: end A, insert B (startedAt = .now,
        // which is DECADES after the 2001-based fixture dates — exactly the
        // gap the backdate must bridge).
        homeA.endedAt = .now
        let homeB = Home(label: "B", latitude: 2, longitude: 0, radiusKm: 25)
        ctx.insert(homeB)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        let reset = await classifier.applyHomeChangeCore(homeID: homeB.id).resetCount
        #expect(reset == 3)

        // Core SAVES: the backdate and distance recompute are visible on a
        // fresh context.
        let homeBID = homeB.id
        let freshCtx = ModelContext(container)
        let savedHomeB = try #require((try? freshCtx.fetch(
            FetchDescriptor<Home>(predicate: #Predicate { $0.id == homeBID })
        ))?.first)
        #expect(savedHomeB.startedAt == date(day: 4))

        let arrivalID = arrival.id
        let savedArrival = try #require((try? freshCtx.fetch(
            FetchDescriptor<Stay>(predicate: #Predicate { $0.id == arrivalID })
        ))?.first)
        #expect(savedArrival.category == .unclassified)
        #expect(savedArrival.trip == nil)
        #expect(savedArrival.distanceFromHomeKm < 2)  // home B active at arrival now

        // Deterministic pipeline seams (no FM): re-stamp, regroup, close.
        let stamped = await classifier.preFilterStays()
        #expect(stamped == 3)  // all three B stays classify .home
        _ = await classifier.assembleTrips()
        _ = await classifier.closeStaleOpenTrips()

        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.count == 1)
        let trip = try #require(trips.first)
        #expect(trip.isComplete)
        // Closed at the REAL homecoming: the last stay before arrival at B.
        #expect(trip.endDate == waypoint.endTime)
    }

    @Test("with two active homes, arriving at either one closes the trip")
    func secondActiveHomeClosesTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        // Genuine dual residence (studying abroad / summer house): BOTH
        // homes active, registered long ago. Multi-home is first-class —
        // the boundary engine is home-identity-agnostic.
        let homeA = Home(label: "Parents", latitude: 0, longitude: 0, radiusKm: 25)
        homeA.startedAt = date(day: -100)
        ctx.insert(homeA)
        let homeB = Home(label: "Study", latitude: 2, longitude: 0, radiusKm: 25)
        homeB.startedAt = date(day: -100)
        ctx.insert(homeB)

        makeStay(in: ctx, startDay: 0, category: .home, latitude: 0)
        let waypoint = makeStay(in: ctx, startDay: 2, category: .destination, latitude: 1)
        // Fresh-from-clusterer arrival at home B, not yet classified.
        makeStay(in: ctx, startDay: 4, category: .unclassified, latitude: 2.0)
        makeOpenTrip(in: ctx, stays: [waypoint], startDay: 2)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        let stamped = await classifier.preFilterStays()
        #expect(stamped == 1)  // the B arrival classifies .home
        _ = await classifier.assembleTrips()
        _ = await classifier.closeStaleOpenTrips()

        let trips = await classifier.assembledTripsForTesting()
        let trip = try #require(trips.first)
        #expect(trip.isComplete)
        #expect(trip.endDate == waypoint.endTime)
    }

    @Test("user-overridden stays inside the new ring are never reset")
    func userOverriddenStaysSacred() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let homeA = Home(label: "A", latitude: 0, longitude: 0, radiusKm: 25)
        homeA.startedAt = date(day: -100)
        homeA.endedAt = .now
        ctx.insert(homeA)

        let pinned = makeStay(in: ctx, startDay: 4, category: .destination, latitude: 2.0)
        pinned.userOverridden = true
        makeStay(in: ctx, startDay: 5, category: .destination, latitude: 2.0)

        let homeB = Home(label: "B", latitude: 2, longitude: 0, radiusKm: 25)
        ctx.insert(homeB)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        let reset = await classifier.applyHomeChangeCore(homeID: homeB.id).resetCount
        #expect(reset == 1)

        let pinnedID = pinned.id
        let freshCtx = ModelContext(container)
        let savedPinned = try #require((try? freshCtx.fetch(
            FetchDescriptor<Stay>(predicate: #Predicate { $0.id == pinnedID })
        ))?.first)
        #expect(savedPinned.category == .destination)
    }

    @Test("registering a home you are not at resets nothing and keeps startedAt")
    func futureHomeRegistrationIsInert() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let homeA = Home(label: "A", latitude: 0, longitude: 0, radiusKm: 25)
        homeA.startedAt = date(day: -100)
        ctx.insert(homeA)
        makeStay(in: ctx, startDay: 0, category: .home, latitude: 0)  // latest stay: at A

        let creationFloor = Date.now.addingTimeInterval(-60)
        let homeB = Home(label: "B", latitude: 2, longitude: 0, radiusKm: 25)
        ctx.insert(homeB)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        // A failed or cancelled reconciliation also projects to zero resets,
        // so the committed outcome itself is the oracle.
        #expect(await classifier.applyHomeChangeCore(homeID: homeB.id) == .committed(resetCount: 0))

        let homeBID = homeB.id
        let freshCtx = ModelContext(container)
        let savedHomeB = try #require((try? freshCtx.fetch(
            FetchDescriptor<Home>(predicate: #Predicate { $0.id == homeBID })
        ))?.first)
        // No backdate: startedAt stays at its creation-time value (real
        // .now, decades past the 2001-based fixture dates).
        #expect(savedHomeB.startedAt >= creationFloor)
    }

    // MARK: - Protected stays and home changes

    @Test("stays in a user-edited trip are never reset by a home change")
    func userEditedTripStaysSacred() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let homeA = Home(label: "A", latitude: 0, longitude: 0, radiusKm: 25)
        homeA.startedAt = date(day: -100)
        homeA.endedAt = .now
        ctx.insert(homeA)

        // A stay inside home B's ring, curated into a user-MERGED trip
        // (stay itself NOT overridden — this is the sibling guard).
        let curated = makeStay(in: ctx, startDay: 4, category: .destination, latitude: 2.0)
        let editedTrip = makeOpenTrip(in: ctx, stays: [curated], startDay: 4)
        editedTrip.userEdited = true
        // Control: a free stay in the same ring must still reset.
        makeStay(in: ctx, startDay: 5, category: .destination, latitude: 2.0)

        let homeB = Home(label: "B", latitude: 2, longitude: 0, radiusKm: 25)
        ctx.insert(homeB)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        let reset = await classifier.applyHomeChangeCore(homeID: homeB.id).resetCount
        #expect(reset == 1)

        let curatedID = curated.id
        let freshCtx = ModelContext(container)
        let savedCurated = try #require((try? freshCtx.fetch(
            FetchDescriptor<Stay>(predicate: #Predicate { $0.id == curatedID })
        ))?.first)
        // Category untouched AND the trip link survives — the detach
        // protection specifically.
        #expect(savedCurated.category == .destination)
        #expect(savedCurated.trip != nil)
    }

    @Test("a shrunk ring unstamps home stays left outside coverage")
    func shrunkRingUnstampsStrandedHomeStays() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        // Home with a 25 km ring; a stay ~22 km out was legitimately home.
        let home = Home(label: "Home", latitude: 2, longitude: 0, radiusKm: 25)
        home.startedAt = date(day: -100)
        ctx.insert(home)
        let fringe = makeStay(in: ctx, startDay: 4, category: .home, latitude: 2.2)
        makeStay(in: ctx, startDay: 5, category: .home, latitude: 2.0)  // core stay, stays home
        // User shrinks the radius to 10 km (Settings minor-edit in place).
        home.radiusKm = 10
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        // Both stays reset: the core stay via the in-ring loop (idempotent —
        // re-stamped `.home` immediately below), the fringe via the
        // stale-home pass (out of the shrunk ring).
        let reset = await classifier.applyHomeChangeCore(homeID: home.id).resetCount
        #expect(reset == 2)

        // The shared matchesHome rule re-stamps ONLY the core stay; the
        // fringe stays unclassified and regroups into a trip.
        let stamped = await classifier.preFilterStays()
        #expect(stamped == 1)

        let fringeID = fringe.id
        let freshCtx = ModelContext(container)
        let savedFringe = try #require((try? freshCtx.fetch(
            FetchDescriptor<Stay>(predicate: #Predicate { $0.id == fringeID })
        ))?.first)
        #expect(savedFringe.category == .unclassified)
    }

    // MARK: - Completed-trip reconciliation on ring changes

    @discardableResult
    private func makeCompletedTrip(in ctx: ModelContext, stays: [Stay], endDay: Double) -> Trip {
        let trip = Trip(startDate: stays.first?.startTime ?? .now)
        trip.isComplete = true
        trip.endDate = date(day: endDay)
        ctx.insert(trip)
        for (order, stay) in stays.enumerated() {
            stay.trip = trip
            stay.orderInTrip = order
        }
        return trip
    }

    @Test("growing the ring over a completed trip's only stay deletes the ghost row")
    func ringGrowDeletesFullyAbsorbedCompletedTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        // Home active since long before the fixture era, originally 5 km.
        let home = Home(label: "A", latitude: 0, longitude: 0, radiusKm: 5)
        home.startedAt = date(day: -100)
        ctx.insert(home)

        // A suburb weekend: one stay about 11 km out, outside the
        // 5 km ring when it happened, inside after the grow.
        let suburb = makeStay(in: ctx, startDay: 1, category: .destination, latitude: 0.1, distanceFromHomeKm: 11)
        let trip = makeCompletedTrip(in: ctx, stays: [suburb], endDay: 2)

        home.radiusKm = 25
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        let reset = await classifier.applyHomeChangeCore(homeID: home.id).resetCount
        #expect(reset == 1)

        // An emptied completed trip must be deleted so it cannot inflate
        // Stats or Wrapped totals.
        let tripID = trip.id
        let freshCtx = ModelContext(container)
        let ghosts = try freshCtx.fetch(
            FetchDescriptor<Trip>(predicate: #Predicate { $0.id == tripID })
        )
        #expect(ghosts.isEmpty)

        let suburbID = suburb.id
        let savedSuburb = try #require(try freshCtx.fetch(
            FetchDescriptor<Stay>(predicate: #Predicate { $0.id == suburbID })
        ).first)
        #expect(savedSuburb.category == .unclassified)
        #expect(savedSuburb.trip == nil)
    }

    @Test("a partially-absorbed completed trip shrinks to its remaining stays and drops the stale title")
    func ringGrowShrinksPartiallyAbsorbedCompletedTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let home = Home(label: "A", latitude: 0, longitude: 0, radiusKm: 5)
        home.startedAt = date(day: -100)
        ctx.insert(home)

        // Far stay survives; the in-grown-ring tail stay is detached and —
        // after the next pipeline pass — becomes the new `.home` boundary,
        // so the trip must now END at that stay's start (closeTrip
        // homecoming semantics), not at the old day-4 homecoming.
        let far = makeStay(in: ctx, startDay: 1, category: .destination, latitude: 2, distanceFromHomeKm: 222)
        let tail = makeStay(in: ctx, startDay: 3, category: .destination, latitude: 0.1, distanceFromHomeKm: 11)
        let trip = makeCompletedTrip(in: ctx, stays: [far, tail], endDay: 4)
        trip.aiGeneratedTitle = "Far & Tail"
        ctx.insert(TripTitleVariant(
            languageTag: "de",
            title: "Fern & Ende",
            sourceTitle: "Far & Tail",
            trip: trip))

        home.radiusKm = 25
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        let reset = await classifier.applyHomeChangeCore(homeID: home.id).resetCount
        #expect(reset == 1)

        let tripID = trip.id
        let freshCtx = ModelContext(container)
        let saved = try #require(try freshCtx.fetch(
            FetchDescriptor<Trip>(predicate: #Predicate { $0.id == tripID })
        ).first)
        #expect(saved.isComplete)
        #expect(Set(saved.orderedStays.map(\.id)) == Set([far.id]))
        #expect(saved.endDate == date(day: 3))
        #expect(saved.aiGeneratedTitle == nil)
        #expect((saved.localizedTitles ?? []).isEmpty)
    }

    @Test("a shrunk completed trip's summary reads the home places this change left, not a snapshot from before it")
    func homeChangeSummaryReadsPostChangeHomePlaces() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let home = Home(label: "A", latitude: 0, longitude: 0, radiusKm: 25)
        home.startedAt = date(day: -100)
        home.locality = "Athens"
        ctx.insert(home)
        // A stale home stamp from a misplaced pin, outside the edited ring.
        let staleHome = makeStay(in: ctx, startDay: 1, category: .home, latitude: 5.0)
        staleHome.locality = "Néa Ionía"
        let inRing = makeStay(in: ctx, startDay: 10, category: .destination, latitude: 0.01)
        inRing.locality = "Athens"
        let neaIonia = makeStay(in: ctx, startDay: 11, category: .destination, latitude: 5.01)
        neaIonia.locality = "Néa Ionía"
        let volos = makeStay(in: ctx, startDay: 12, category: .destination, latitude: 3.0)
        volos.locality = "Volos"
        let trip = makeCompletedTrip(in: ctx, stays: [inRing, neaIonia, volos], endDay: 13)
        try ctx.save()

        // A concurrent reader fills the index before the unit runs.
        #expect(try TripTitleStore.homePlaceNames(
            tripStart: date(day: 10), tripEnd: date(day: 13),
            in: ModelContext(container)).contains("nea ionia"))

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.applyHomeChangeCore(homeID: home.id).resetCount == 2)

        let tripID = trip.id
        let saved = try #require(try ModelContext(container).fetch(
            FetchDescriptor<Trip>(predicate: #Predicate { $0.id == tripID })
        ).first)
        #expect(saved.destinationSummary == "Néa Ionía, Volos")
    }

    @Test("detaching a stay from an ongoing trip invalidates its canonical and localized titles")
    func ringGrowInvalidatesOngoingTripTitles() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let home = Home(label: "A", latitude: 0, longitude: 0, radiusKm: 5)
        home.startedAt = date(day: -100)
        ctx.insert(home)

        let far = makeStay(
            in: ctx, startDay: 1, category: .destination,
            latitude: 2, distanceFromHomeKm: 222)
        let absorbed = makeStay(
            in: ctx, startDay: 2, category: .destination,
            latitude: 0.1, distanceFromHomeKm: 11)
        let trip = makeOpenTrip(in: ctx, stays: [far, absorbed], startDay: 1)
        trip.aiGeneratedTitle = "Far & Suburb"
        ctx.insert(TripTitleVariant(
            languageTag: "de",
            title: "Ferne & Vorstadt",
            sourceTitle: "Far & Suburb",
            trip: trip))
        let tripID = trip.id

        home.radiusKm = 25
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.applyHomeChangeCore(homeID: home.id).resetCount == 1)

        let fresh = ModelContext(container)
        let saved = try #require(try fresh.fetch(
            FetchDescriptor<Trip>(predicate: #Predicate { $0.id == tripID })
        ).first)
        #expect(!saved.isComplete)
        #expect(saved.aiGeneratedTitle == nil)
        #expect((saved.localizedTitles ?? []).isEmpty)
    }

    @Test("a remnant with no destination is errand residue — the trip is deleted, not kept blank")
    func ringGrowDeletesAllTransitRemnantTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let home = Home(label: "A", latitude: 0, longitude: 0, radiusKm: 5)
        home.startedAt = date(day: -100)
        ctx.insert(home)

        // Airport leg far outside any ring; BOTH destinations inside the
        // grown ring — the reset loop detaches every destination while the
        // out-of-ring transit leg stays attached.
        let leg = makeStay(in: ctx, startDay: 1, category: .transit, latitude: 2, distanceFromHomeKm: 222)
        let hotel = makeStay(in: ctx, startDay: 1.5, category: .destination, latitude: 0.1, distanceFromHomeKm: 11)
        let dinner = makeStay(in: ctx, startDay: 2, category: .destination, latitude: 0.12, distanceFromHomeKm: 13)
        let trip = makeCompletedTrip(in: ctx, stays: [leg, hotel, dinner], endDay: 3)

        home.radiusKm = 25
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        let reset = await classifier.applyHomeChangeCore(homeID: home.id).resetCount
        #expect(reset == 2)

        // Pre-fix, the shrink branch kept the trip with only the transit
        // leg attached — empty destinationSummary/countryCodes, a blank
        // completed ghost card. No destination ⇒ no journey: the row is
        // deleted and the leg detaches into the tripless-transit steady
        // state the destination-only dirty gate tolerates.
        let tripID = trip.id
        let freshCtx = ModelContext(container)
        let ghosts = try freshCtx.fetch(
            FetchDescriptor<Trip>(predicate: #Predicate { $0.id == tripID })
        )
        #expect(ghosts.isEmpty)

        let legID = leg.id
        let savedLeg = try #require(try freshCtx.fetch(
            FetchDescriptor<Stay>(predicate: #Predicate { $0.id == legID })
        ).first)
        #expect(savedLeg.category == .transit)
        #expect(savedLeg.trip == nil)
    }

    @Test("matchesHome: gap between two historical homes is NOT home")
    func matchesHomeGapRule() {
        let rings = [
            TripClassifier.HomeRing(latitude: 0, longitude: 0, radiusKm: 25,
                                    startedAt: date(day: -200), endedAt: date(day: -100)),
            TripClassifier.HomeRing(latitude: 2, longitude: 0, radiusKm: 25,
                                    startedAt: date(day: 0), endedAt: nil),
        ]
        // During the gap, at the OLD home's location: not home (window over).
        #expect(!TripClassifier.matchesHome(
            stayStart: date(day: -50), latitude: 0, longitude: 0, homes: rings
        ))
        // Pre-history at the CURRENT home's location: fallback applies.
        #expect(TripClassifier.matchesHome(
            stayStart: date(day: -300), latitude: 2, longitude: 0, homes: rings
        ))
        // No homes at all: nothing is home.
        #expect(!TripClassifier.matchesHome(
            stayStart: .now, latitude: 0, longitude: 0, homes: []
        ))
    }

    @Test("home save decision seams: dialog wiring and reconcile triggers")
    func homeSaveDecisionSeams() {
        // Only the explicit replace choice ends existing homes — a swapped
        // dialog wiring fails here.
        #expect(!HomeSaveDecision.endsExistingHomes(.keepBothHomes))
        #expect(HomeSaveDecision.endsExistingHomes(.replaceExistingHomes))
        // The choice dialog appears only for adds alongside active homes.
        #expect(HomeSaveDecision.promptsAddChoice(isAdd: true, activeHomeCount: 1))
        #expect(!HomeSaveDecision.promptsAddChoice(isAdd: true, activeHomeCount: 0))
        #expect(!HomeSaveDecision.promptsAddChoice(isAdd: false, activeHomeCount: 3))
        // Coverage changes reconcile; label-only edits don't.
        #expect(HomeSaveDecision.coverageChanged(
            oldLatitude: 0, oldLongitude: 0, oldRadiusKm: 5,
            newLatitude: 0, newLongitude: 0, newRadiusKm: 25
        ))
        #expect(HomeSaveDecision.coverageChanged(
            oldLatitude: 0, oldLongitude: 0, oldRadiusKm: 25,
            newLatitude: 0.001, newLongitude: 0, newRadiusKm: 25
        ))
        #expect(!HomeSaveDecision.coverageChanged(
            oldLatitude: 0, oldLongitude: 0, oldRadiusKm: 25,
            newLatitude: 0, newLongitude: 0, newRadiusKm: 25
        ))
    }

    @Test("home deletion may never end the last active home")
    func homeDeletionGuard() {
        let a = UUID(), b = UUID()
        // Deleting one of two actives proceeds.
        #expect(HomeSaveDecision.endableHomeIDs(requested: [a], activeIDs: [a, b]) == [a])
        // Deleting the ONLY active home is refused outright — with zero
        // active homes nothing can classify `.home`, no trip can close, and
        // the confidence gate falls into its home-less decline path.
        #expect(HomeSaveDecision.endableHomeIDs(requested: [a], activeIDs: [a]).isEmpty)
        // A request covering BOTH actives is refused WHOLE, never trimmed to
        // an arbitrary survivor the user didn't choose.
        #expect(HomeSaveDecision.endableHomeIDs(requested: [a, b], activeIDs: [a, b]).isEmpty)
        // Degenerate inputs stay inert.
        #expect(HomeSaveDecision.endableHomeIDs(requested: [], activeIDs: [a]).isEmpty)
        // A stale request naming a non-active id alongside a real one still
        // ends the real one (the gated re-validation filters rows by the
        // CURRENT active set) — b survives, so the set can't empty.
        let stale = UUID()
        #expect(HomeSaveDecision.endableHomeIDs(
            requested: [a, stale], activeIDs: [a, b]) == [a, stale])
    }

    @Test("an un-geocoded active home resolves its country from in-ring home stays")
    func unGeocodedHomeResolvesCountry() {
        let homes = [
            StatsAggregator.ActiveHomeGeo(isoCountryCode: "GR", latitude: 0, longitude: 0, radiusKm: 25),
            StatsAggregator.ActiveHomeGeo(isoCountryCode: nil, latitude: 2, longitude: 0, radiusKm: 25),
        ]
        let homeStays: [(iso: String?, latitude: Double, longitude: Double)] = [
            ("GR", 0, 0),
            ("DE", 2.0, 0), ("DE", 2.01, 0),  // inside the nil-code home's ring
            ("FR", 5, 0),                      // far away — must not leak in
            (nil, 2.0, 0),                     // un-geocoded stay contributes nothing
        ]
        let codes = StatsAggregator.resolveHomeCountryCodes(homes: homes, homeStays: homeStays)
        #expect(codes == ["GR", "DE"])
        // No in-ring evidence: the home contributes nothing (no phantom).
        let none = StatsAggregator.resolveHomeCountryCodes(
            homes: [StatsAggregator.ActiveHomeGeo(isoCountryCode: nil, latitude: 50, longitude: 0, radiusKm: 25)],
            homeStays: homeStays
        )
        #expect(none.isEmpty)
    }

    @Test("compute keeps the badge + pin for an un-geocoded active home (mixed state)")
    func mixedGeocodeHomesKeepBothBadges() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let athens = Home(label: "Athens", latitude: 0, longitude: 0, radiusKm: 25)
        athens.isoCountryCode = "GR"
        ctx.insert(athens)
        let berlin = Home(label: "Berlin", latitude: 2, longitude: 0, radiusKm: 25)
        // isoCountryCode deliberately nil — creation-time geocode failed.
        ctx.insert(berlin)

        let grStay = makeStay(in: ctx, startDay: 0, category: .home, latitude: 0)
        grStay.isoCountryCode = "GR"
        grStay.country = "Greece"
        let deStay = makeStay(in: ctx, startDay: 1, category: .home, latitude: 2.0)
        deStay.isoCountryCode = "DE"
        deStay.country = "Germany"
        try ctx.save()

        let result = try StatsAggregator.compute(container: container)
        // Pre-fix: homeCountryCodes = {GR} only, so the override stripped
        // Germany's badge and the DE home pin never rendered.
        #expect(result.countryStats.first { $0.code == "DE" }?.isHome == true)
        #expect(result.countryStats.first { $0.code == "GR" }?.isHome == true)
        #expect(result.homeHexCountries?.contains { $0.code == "DE" } == true)
    }

    // MARK: - Wrapped farthest (pure)

    @Test("farthest uses stored distances; sentinel and impossible values never win")
    func farthestSentinelGuard() {
        let id1 = UUID(), id2 = UUID(), id3 = UUID()
        let result = YearWrappedGenerator.farthestFromHome(destinations: [
            (distanceKm: 500, startTime: date(day: 1), id: id1, name: "Paris"),
            (distanceKm: Double.greatestFiniteMagnitude, startTime: date(day: 2), id: id2, name: "Broken"),
            (distanceKm: 30_000, startTime: date(day: 3), id: id3, name: "Impossible"),
        ])
        #expect(result?.distanceKm == 500)
        #expect(result?.name == "Paris")
        let empty = YearWrappedGenerator.farthestFromHome(destinations: [])
        #expect(empty?.distanceKm == nil)
    }

    @Test("farthest ties break deterministically: earlier start, then smaller id")
    func farthestDeterministicTies() {
        let earlier = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let later = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let byDate = YearWrappedGenerator.farthestFromHome(destinations: [
            (distanceKm: 500, startTime: date(day: 2), id: later, name: "Later"),
            (distanceKm: 500, startTime: date(day: 1), id: earlier, name: "Earlier"),
        ])
        #expect(byDate?.name == "Earlier")
        let byID = YearWrappedGenerator.farthestFromHome(destinations: [
            (distanceKm: 500, startTime: date(day: 1), id: later, name: "BigID"),
            (distanceKm: 500, startTime: date(day: 1), id: earlier, name: "SmallID"),
        ])
        #expect(byID?.name == "SmallID")
    }

    // MARK: - Present-tense country home badge

    private func makeBadgeStay(category: StayCategory, iso: String, country: String) -> Stay {
        let stay = Stay(
            startTime: .now, endTime: .now,
            centroidLatitude: 0, centroidLongitude: 0,
            h3IndexRes6: "", pingCount: 1,
            distanceFromHomeKm: 0, pingIDs: []
        )
        stay.category = category
        stay.isoCountryCode = iso
        stay.country = country
        return stay
    }

    @Test("active home's country wins the badge; the old country loses it after a move")
    func homeBadgeIsPresentTense() {
        let stays = [
            makeBadgeStay(category: .home, iso: "GR", country: "Greece"),
            makeBadgeStay(category: .destination, iso: "NL", country: "Netherlands"),
        ]
        let result = StatsAggregator.aggregate(
            visitedStays: stays, transitStays: [], trips: [],
            hexVisits: [], totalPings: 0, totalStays: 2,
            flightCount: 0, trackingSince: nil,
            homeCountryCodes: ["NL"]
        )
        #expect(result.countryStats.first { $0.code == "GR" }?.isHome == false)
        #expect(result.countryStats.first { $0.code == "NL" }?.isHome == true)
    }

    @Test("without a stamped active home the stay-derived badge survives")
    func homeBadgeFallback() {
        let stays = [
            makeBadgeStay(category: .home, iso: "GR", country: "Greece"),
            makeBadgeStay(category: .destination, iso: "NL", country: "Netherlands"),
        ]
        let result = StatsAggregator.aggregate(
            visitedStays: stays, transitStays: [], trips: [],
            hexVisits: [], totalPings: 0, totalStays: 2,
            flightCount: 0, trackingSince: nil
        )
        #expect(result.countryStats.first { $0.code == "GR" }?.isHome == true)
        #expect(result.countryStats.first { $0.code == "NL" }?.isHome == false)
    }
}
