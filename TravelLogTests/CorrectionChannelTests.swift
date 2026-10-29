//
//  CorrectionChannelTests.swift
//  TravelLogTests
//
//  Trip logging and home-area corrections:
//
//  "Log as a trip": `suppressedGroups()` reconstructs the gate's
//  tripless residue as the groups assembly saw (split at qualifying home
//  boundaries); `logSuppressedGroupAsTrip` stamps `userOverridden`, the
//  gate exempts the group, and the next assembly pass creates the trip
//  through the normal path.
//
//  Trip demotion ("This wasn't a trip"): `demoteTripToHomeArea` persists an
//  `.include` HomeAreaOverride at the trip's dominant cluster, settles the
//  present by stamping the members `.home` + `userOverridden`, deletes the
//  trip; `withShapes` carries the override into membership so future stays
//  in the taught area count as home; `undoLastDemotion` reverses all of it.
//
//  Same harness as HomeShapeGateTests (square urban centre, D* ≈ 5.64 km,
//  reference-date day offsets; everything UTC-safe).
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
struct CorrectionChannelTests {

    private static let day: TimeInterval = 24 * 60 * 60
    private static let home = (lat: 38.0320, lon: 23.7161)
    /// Far spot: ~0.14° east of the square's edge (≈12 km beyond it).
    private static let village = (lat: 38.0320, lon: 23.9061)

    private func date(day offset: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: (offset + 119) * Self.day)
    }

    private static func squareShape() -> HomeShape {
        HomeShape.urbanCentre(
            id: 1, name: "TestCity", areaKm2: 100,
            rings: [[[23.6661, 37.9820, 23.7661, 37.9820, 23.7660, 38.0820, 23.6660, 38.0820]]],
            centreLatitude: home.lat, centreLongitude: home.lon)
    }

    @discardableResult
    private func makeStay(
        in ctx: ModelContext, startDay: Double, durationHours: Double = 2,
        latitude: Double, longitude: Double,
        category: StayCategory = .destination, hex: String,
        locality: String? = nil
    ) -> Stay {
        let start = date(day: startDay)
        let stay = Stay(
            startTime: start, endTime: start.addingTimeInterval(durationHours * 3600),
            centroidLatitude: latitude, centroidLongitude: longitude,
            h3IndexRes6: hex, pingCount: 2, distanceFromHomeKm: 15, pingIDs: [])
        stay.category = category
        stay.locality = locality
        ctx.insert(stay)
        return stay
    }

    @discardableResult
    private func makeHome(in ctx: ModelContext, startDay: Double) -> Home {
        let home = Home(label: "Home", latitude: Self.home.lat,
                        longitude: Self.home.lon, radiusKm: 25,
                        startedAt: date(day: startDay))
        ctx.insert(home)
        return home
    }

    // MARK: - Log as a trip

    @Test("suppressedGroups reconstructs assembly grouping: split at home stays, trip members invisible")
    func suppressedGroupsMirrorAssembly() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(in: ctx, startDay: -10)
        // Group 1: two tripless destination stays.
        makeStay(in: ctx, startDay: 0, latitude: 38.0320, longitude: 23.8561,
                 hex: "A", locality: "Errandville")
        makeStay(in: ctx, startDay: 0.2, latitude: 38.0320, longitude: 23.8561,
                 hex: "A", locality: "Errandville")
        // Home boundary.
        makeStay(in: ctx, startDay: 1, latitude: Self.home.lat,
                 longitude: Self.home.lon, category: .home, hex: "H")
        // Group 2: one more suppressed stay.
        makeStay(in: ctx, startDay: 2, latitude: 38.0320, longitude: 23.8561,
                 hex: "B", locality: "Errandville")
        // A stay INSIDE a trip must be invisible to the review list.
        let trip = Trip(startDate: date(day: 5))
        trip.isComplete = true
        trip.endDate = date(day: 6)
        ctx.insert(trip)
        let member = makeStay(in: ctx, startDay: 5, latitude: 38.4,
                              longitude: 24.0, hex: "C")
        member.trip = trip
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        let groups = await classifier.suppressedGroups()
        #expect(groups.count == 2)
        #expect(groups[0].stayIDs.count == 2)
        #expect(groups[1].stayIDs.count == 1)
        #expect(groups[0].placeName == "Errandville")
        #expect(groups[0].dwellHours == 4.0)
    }

    @Test("Log as a trip end-to-end: a gate-suppressed group logged as a trip mints on the next pass")
    func armAEndToEnd() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(in: ctx, startDay: -10)
        // Sub-θ errand: ~7.9 km beyond the edge, 4 h total (the pinned
        // suppression fixture from HomeShapeGateTests).
        makeStay(in: ctx, startDay: 0, latitude: 38.0320, longitude: 23.8561, hex: "A")
        makeStay(in: ctx, startDay: 0.1, latitude: 38.0320, longitude: 23.8561, hex: "A")
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        #expect(await classifier.assembleTrips() == 0, "suppressed pre-correction")
        #expect(await classifier.assemblyInvariantViolatedForTesting() == false)

        let groups = await classifier.suppressedGroups()
        #expect(groups.count == 1)
        let stamped = await classifier.logSuppressedGroupAsTrip(
            stayIDs: groups[0].stayIDs)
        #expect(stamped == 2)
        // The stale suppression fingerprints must not excuse the stamped
        // stays, or the gated pipeline would skip the back half.
        #expect(await classifier.assemblyInvariantViolatedForTesting() == true)

        // The gate exempts userOverridden groups → the trip now mints.
        // (Return-value assertion only: assembleTrips deliberately doesn't
        // save, so a sibling context can't observe the row; the documented
        // OngoingTripReuseTests seeding pattern.)
        #expect(await classifier.assembleTrips() == 1)
        // And the correction is settled: a second pass creates nothing new.
        #expect(await classifier.assembleTrips() == 0)
        #expect(await classifier.assemblyInvariantViolatedForTesting() == false)
    }

    @Test("suppressedGroups does not split at a non-qualifying home stay")
    func suppressedGroupsIgnoreNonQualifyingHome() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(in: ctx, startDay: -10)
        makeStay(in: ctx, startDay: 0, latitude: 38.0320, longitude: 23.8561, hex: "A")
        // A single-fix live home stay is not an assembly boundary.
        let blip = makeStay(in: ctx, startDay: 0.15, durationHours: 0.1,
                            latitude: Self.home.lat, longitude: Self.home.lon,
                            category: .home, hex: "H")
        blip.pingCount = 1
        makeStay(in: ctx, startDay: 0.3, latitude: 38.0320, longitude: 23.8561, hex: "A")
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        #expect(await classifier.assembleTrips() == 0)
        let groups = await classifier.suppressedGroups()
        #expect(groups.count == 1)
        #expect(groups.first?.stayIDs.count == 2)
        let stamped = await classifier.logSuppressedGroupAsTrip(
            stayIDs: groups.first?.stayIDs ?? [])
        #expect(stamped == 2)
        #expect(await classifier.assembleTrips() == 1)
    }

    @Test("suppressedGroups does not split at a week-plus evidence gap")
    func suppressedGroupsIgnoreEvidenceGap() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(in: ctx, startDay: -10)
        makeStay(in: ctx, startDay: 0, latitude: 38.0320, longitude: 23.8561, hex: "A")
        makeStay(in: ctx, startDay: 21, latitude: 38.0320, longitude: 23.8561, hex: "A")
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        #expect(await classifier.assembleTrips() == 0)
        let groups = await classifier.suppressedGroups()
        #expect(groups.count == 1)
        #expect(groups.first?.stayIDs.count == 2)
        let stamped = await classifier.logSuppressedGroupAsTrip(
            stayIDs: groups.first?.stayIDs ?? [])
        #expect(stamped == 2)
        #expect(await classifier.assembleTrips() == 1)
    }

    /// ~135 km beyond the square's edge, out at sea: past θ even for a short stop.
    private static let farTown = (lat: 38.0320, lon: 25.3)

    /// Two short transit stops at `farTown` from `startDay`, then home unless `open`.
    private func transitOuting(in ctx: ModelContext, startDay: Double, longitude: Double = farTown.lon,
                               open: Bool = false) -> [Stay] {
        let stops = [
            makeStay(in: ctx, startDay: startDay, durationHours: 0.3, latitude: Self.farTown.lat,
                     longitude: longitude, category: .transit, hex: "T", locality: "Farton"),
            makeStay(in: ctx, startDay: startDay + 0.02, durationHours: 0.25, latitude: Self.farTown.lat,
                     longitude: longitude, category: .transit, hex: "T", locality: "Farton"),
        ]
        if !open {
            makeStay(in: ctx, startDay: startDay + 0.1, latitude: Self.home.lat,
                     longitude: Self.home.lon, category: .home, hex: "H")
        }
        return stops
    }

    @Test("a closed all-transit outing that clears θ is listed; a sub-θ errand and an open tail are not")
    func closedTransitOutingIsListed() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(in: ctx, startDay: -10)
        let outing = transitOuting(in: ctx, startDay: 0)
        // The sub-θ errand spot of `armAEndToEnd`, with only short stops.
        _ = transitOuting(in: ctx, startDay: 1, longitude: 23.8561)
        _ = transitOuting(in: ctx, startDay: 2, open: true)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        // Assembly mints no trip from any of them.
        #expect(await classifier.assembleTrips() == 0)
        let groups = await classifier.suppressedGroups()
        #expect(groups.map(\.stayIDs) == [outing.map(\.id)])
        #expect(groups.first?.placeName == "Farton")
    }

    @Test("Log as a trip on an all-transit outing makes its longest stop the destination")
    func loggingTransitOutingMintsTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(in: ctx, startDay: -10)
        let outing = transitOuting(in: ctx, startDay: 0)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        #expect(await classifier.assembleTrips() == 0)
        let groups = await classifier.suppressedGroups()
        #expect(groups.count == 1)
        #expect(await classifier.logSuppressedGroupAsTrip(stayIDs: groups.first?.stayIDs ?? []) == 1)
        #expect(await classifier.stayCategoryForTesting(outing[0].id) == .destination)
        #expect(await classifier.stayCategoryForTesting(outing[1].id) == .transit)
        #expect(await classifier.assembleTrips() == 1)
        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.count == 1)
        #expect(await classifier.tripStayIDsForTesting(trips[0].id) == Set(outing.map(\.id)))
        #expect(await classifier.suppressedGroups().isEmpty)
    }

    @Test("outings the gap judge separates are scored apart, as assembly scores them")
    func judgedGapSplitsTransitOutings() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(in: ctx, startDay: -10)
        makeStay(in: ctx, startDay: -1, latitude: Self.home.lat, longitude: Self.home.lon,
                 category: .home, hex: "H")
        // A short stop ~12 km beyond the east edge, then two days later one as
        // far beyond the west edge, with no home stay recorded between: each is
        // below θ alone, the two days together clear it, and home lies on the
        // way from one to the other, so the judge ends a trip in the gap.
        for (day, longitude) in [(0.0, Self.village.lon), (2.0, 23.5261)] {
            makeStay(in: ctx, startDay: day, durationHours: 0.3, latitude: Self.village.lat,
                     longitude: longitude, category: .transit, hex: "T")
        }
        makeStay(in: ctx, startDay: 2.1, latitude: Self.home.lat, longitude: Self.home.lon,
                 category: .home, hex: "H")
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        #expect(await classifier.assembleTrips() == 0)
        #expect(await classifier.suppressedGroups().isEmpty)
    }

    @Test("Log as a trip never changes a UUID twin the user set")
    func loggingTransitOutingSparesUserSetTwin() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(in: ctx, startDay: -10)
        let outing = transitOuting(in: ctx, startDay: 0)
        let twin = makeStay(in: ctx, startDay: 0, durationHours: 0.3, latitude: Self.farTown.lat,
                            longitude: Self.farTown.lon, category: .transit, hex: "T")
        twin.id = outing[0].id
        twin.userOverridden = true
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.logSuppressedGroupAsTrip(stayIDs: outing.map(\.id)) == 1)
        let id = outing[0].id
        let copies = try ModelContext(container).fetch(FetchDescriptor<Stay>(
            predicate: #Predicate { $0.id == id }))
        #expect(copies.count == 2)
        #expect(copies.filter { $0.userOverridden && $0.category == .destination }.count == 1)
        #expect(copies.filter { $0.category == .transit }.count == 1)
    }

    @Test("Log as a trip re-validates: stays that joined a trip since rendering are skipped")
    func armARevalidates() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(in: ctx, startDay: -10)
        let stay = makeStay(in: ctx, startDay: 0, latitude: 38.0320,
                            longitude: 23.8561, hex: "A")
        try ctx.save()
        let staleID = stay.id

        // The stay gains a trip between render and tap.
        let trip = Trip(startDate: date(day: 0))
        ctx.insert(trip)
        stay.trip = trip
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.logSuppressedGroupAsTrip(stayIDs: [staleID]) == 0)
    }

    @Test("Log as a trip reports a failed save and leaves the group unstamped")
    func armASaveFailureRollsBack() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(in: ctx, startDay: -10)
        makeStay(in: ctx, startDay: 0, latitude: 38.0320, longitude: 23.8561, hex: "A")
        makeStay(in: ctx, startDay: 0.1, latitude: 38.0320, longitude: 23.8561, hex: "A")
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        #expect(await classifier.assembleTrips() == 0)
        let groups = await classifier.suppressedGroups()
        #expect(groups.count == 1)

        await classifier.failNextLogAsTripSaveForTesting()
        let stamped = await classifier.logSuppressedGroupAsTrip(
            stayIDs: groups.first?.stayIDs ?? [])
        #expect(stamped == nil)
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        // Rolled back: the group is still offered, and nothing reached the store.
        #expect(await classifier.suppressedGroups().first?.stayIDs == groups.first?.stayIDs)
        let stays = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        #expect(stays.allSatisfy { !$0.userOverridden })

        // The retry commits.
        #expect(await classifier.logSuppressedGroupAsTrip(
            stayIDs: groups.first?.stayIDs ?? []) == 2)
    }

    // MARK: - Trip demotion

    @Test("Trip demotion persists an include override, settles stays as sacred home, deletes the trip")
    func armBDemote() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let home = makeHome(in: ctx, startDay: -10)
        let trip = Trip(startDate: date(day: 0))
        trip.endDate = date(day: 0.5)
        trip.isComplete = true
        trip.customName = "Errand That Was Not A Trip"
        ctx.insert(trip)
        let a = makeStay(in: ctx, startDay: 0, latitude: Self.village.lat,
                         longitude: Self.village.lon, hex: "V")
        let b = makeStay(in: ctx, startDay: 0.2, latitude: Self.village.lat,
                         longitude: Self.village.lon, hex: "V")
        a.trip = trip; a.orderInTrip = 0
        b.trip = trip; b.orderInTrip = 1
        try ctx.save()
        let tripID = trip.id

        let classifier = TripClassifier(modelContainer: container)
        let outcome = await classifier.demoteSeededTrip(tripID)
        #expect(outcome == .demoted(tripName: "Errand That Was Not A Trip"))

        let overrides = try ctx.fetch(FetchDescriptor<HomeAreaOverride>())
        #expect(overrides.count == 1)
        let row = try #require(overrides.first)
        #expect(row.kind == .include)
        #expect(row.homeID == home.id)
        #expect(abs(row.centerLatitude - Self.village.lat) < 0.01)
        #expect(row.sourceTripName == "Errand That Was Not A Trip")

        let trips = try ctx.fetch(FetchDescriptor<Trip>())
        #expect(trips.isEmpty)
        for stay in try ctx.fetch(FetchDescriptor<Stay>()) {
            #expect(stay.category == .home)
            #expect(stay.userOverridden)
            #expect(stay.trip == nil)
        }
    }

    @Test("Trip demotion teaches the future: after demotion, the spot is home membership on the next pass")
    func armBFutureMembership() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let home = makeHome(in: ctx, startDay: -10)
        let trip = Trip(startDate: date(day: 0))
        trip.endDate = date(day: 0.5)
        trip.isComplete = true
        ctx.insert(trip)
        let a = makeStay(in: ctx, startDay: 0, latitude: Self.village.lat,
                         longitude: Self.village.lon, hex: "V")
        a.trip = trip
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        _ = await classifier.demoteSeededTrip(trip.id)

        // The membership the pipeline now runs with must claim the spot.
        let rings = await classifier.withShapes([TripClassifier.HomeRing(
            latitude: Self.home.lat, longitude: Self.home.lon, radiusKm: 25,
            startedAt: date(day: -10), endedAt: nil, homeID: home.id)])
        let membership = try #require(rings.first?.membership)
        #expect(membership.contains(latitude: Self.village.lat,
                                    longitude: Self.village.lon,
                                    at: date(day: 30)))
        // …and the seed's scale did not move (E2.4).
        #expect(membership.scaleKm == Self.squareShape().areaEquivalentRadiusKm)
    }

    @Test("Trip demotion undo: stays restored, override deleted, second undo is a no-op")
    func armBUndo() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(in: ctx, startDay: -10)
        let trip = Trip(startDate: date(day: 0))
        trip.endDate = date(day: 0.5)
        trip.isComplete = true
        ctx.insert(trip)
        let a = makeStay(in: ctx, startDay: 0, latitude: Self.village.lat,
                         longitude: Self.village.lon, hex: "V")
        a.trip = trip
        try ctx.save()
        let stayID = a.id

        let classifier = TripClassifier(modelContainer: container)
        _ = await classifier.demoteSeededTrip(trip.id)
        #expect(await classifier.undoLastDemotion() == .undone)

        let stays = try ctx.fetch(FetchDescriptor<Stay>())
        let restored = try #require(stays.first { $0.id == stayID })
        #expect(restored.category == .destination)
        #expect(!restored.userOverridden)
        #expect(try ctx.fetch(FetchDescriptor<HomeAreaOverride>()).isEmpty)
        #expect(await classifier.undoLastDemotion() == .unavailable)
    }

    @Test("Trip demotion undo restores the trip's hidden and pinned photo rows")
    func armBUndoRestoresPhotoAnnotations() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(in: ctx, startDay: -10)
        let trip = Trip(startDate: date(day: 0))
        trip.endDate = date(day: 0.5)
        trip.isComplete = true
        ctx.insert(trip)
        let a = makeStay(in: ctx, startDay: 0, latitude: Self.village.lat,
                         longitude: Self.village.lon, hex: "V")
        a.trip = trip
        let hidden = HiddenPhoto(localIdentifier: "H1", tripID: trip.id)
        hidden.cloudIdentifier = "cH1"
        ctx.insert(hidden)
        ctx.insert(PinnedPhoto(localIdentifier: "P1", tripID: trip.id))
        try ctx.save()
        let tripID = trip.id

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.demoteSeededTrip(tripID).isDemoted)
        #expect(try ctx.fetch(FetchDescriptor<HiddenPhoto>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<PinnedPhoto>()).isEmpty)
        #expect(await classifier.undoLastDemotion() == .undone)

        let hiddenRows = try ctx.fetch(FetchDescriptor<HiddenPhoto>())
        #expect(hiddenRows.count == 1)
        #expect(hiddenRows.first?.tripID == tripID)
        #expect(hiddenRows.first?.localIdentifier == "H1")
        #expect(hiddenRows.first?.cloudIdentifier == "cH1")
        let pinnedRows = try ctx.fetch(FetchDescriptor<PinnedPhoto>())
        #expect(pinnedRows.count == 1)
        #expect(pinnedRows.first?.tripID == tripID)
        #expect(pinnedRows.first?.localIdentifier == "P1")
        #expect(try ctx.fetch(FetchDescriptor<Trip>()).contains { $0.id == tripID })
    }

    /// A completed one-stay village trip with one hidden and one pinned photo row.
    private func makeAnnotatedVillageTrip(
        in ctx: ModelContext
    ) throws -> (trip: Trip, stay: Stay, hiddenID: UUID, pinnedID: UUID) {
        makeHome(in: ctx, startDay: -10)
        let trip = Trip(startDate: date(day: 0))
        trip.endDate = date(day: 0.5)
        trip.isComplete = true
        ctx.insert(trip)
        let stay = makeStay(in: ctx, startDay: 0, latitude: Self.village.lat,
                            longitude: Self.village.lon, hex: "V")
        stay.trip = trip
        let hidden = HiddenPhoto(localIdentifier: "H1", tripID: trip.id)
        hidden.cloudIdentifier = "cH1"
        ctx.insert(hidden)
        let pinned = PinnedPhoto(localIdentifier: "P1", tripID: trip.id)
        ctx.insert(pinned)
        try ctx.save()
        return (trip, stay, hidden.id, pinned.id)
    }

    private func expectOriginalPhotoRows(
        in ctx: ModelContext, tripID: UUID, hiddenID: UUID, pinnedID: UUID
    ) throws {
        let hiddenRows = try ctx.fetch(FetchDescriptor<HiddenPhoto>())
        #expect(hiddenRows.map(\.localIdentifier) == ["H1"])
        #expect(hiddenRows.first?.id == hiddenID)
        #expect(hiddenRows.first?.tripID == tripID)
        #expect(hiddenRows.first?.cloudIdentifier == "cH1")
        let pinnedRows = try ctx.fetch(FetchDescriptor<PinnedPhoto>())
        #expect(pinnedRows.map(\.localIdentifier) == ["P1"])
        #expect(pinnedRows.first?.id == pinnedID)
        #expect(pinnedRows.first?.tripID == tripID)
    }

    private func expectStillDemoted(
        in ctx: ModelContext, stayID: UUID
    ) throws {
        #expect(try ctx.fetch(FetchDescriptor<Trip>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<HiddenPhoto>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<PinnedPhoto>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<HomeAreaOverride>()).count == 1)
        let stay = try #require(try ctx.fetch(FetchDescriptor<Stay>())
            .first { $0.id == stayID })
        #expect(stay.category == .home)
        #expect(stay.userOverridden)
        #expect(stay.trip == nil)
    }

    @Test("Trip demotion undo that cannot commit the trip and its photo rows reports failure and stays retryable")
    func armBUndoSaveFailureKeepsPhotoAnnotations() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let fixture = try makeAnnotatedVillageTrip(in: ctx)
        let tripID = fixture.trip.id
        let stayID = fixture.stay.id

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.demoteSeededTrip(tripID).isDemoted)

        await classifier.failNextDissolvedRestoreSave()
        #expect(await classifier.undoLastDemotion() == .failed)
        try expectStillDemoted(in: ctx, stayID: stayID)

        #expect(await classifier.undoLastDemotion() == .undone)
        #expect(try ctx.fetch(FetchDescriptor<Trip>()).map(\.id) == [tripID])
        try expectOriginalPhotoRows(
            in: ctx, tripID: tripID,
            hiddenID: fixture.hiddenID, pinnedID: fixture.pinnedID)
        #expect(try ctx.fetch(FetchDescriptor<HomeAreaOverride>()).isEmpty)
        let stay = try #require(try ctx.fetch(FetchDescriptor<Stay>())
            .first { $0.id == stayID })
        #expect(stay.category == .destination)
        #expect(!stay.userOverridden)
    }

    @Test("Trip demotion undo whose photo-row read fails reports failure and stays retryable")
    func armBUndoAnnotationReadFailureKeepsPhotoAnnotations() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let fixture = try makeAnnotatedVillageTrip(in: ctx)
        let tripID = fixture.trip.id

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.demoteSeededTrip(tripID).isDemoted)

        // Restore reads the trip identity, the stays, then the hidden and
        // pinned rows already keyed to the trip.
        await classifier.failDissolvedRestoreFetchCallForTesting(4)
        #expect(await classifier.undoLastDemotion() == .failed)
        try expectStillDemoted(in: ctx, stayID: fixture.stay.id)

        #expect(await classifier.undoLastDemotion() == .undone)
        try expectOriginalPhotoRows(
            in: ctx, tripID: tripID,
            hiddenID: fixture.hiddenID, pinnedID: fixture.pinnedID)
    }

    @Test("Trip demotion undo onto a trip row that synced back first restores its photo rows or reports failure")
    func armBUndoOntoExistingTripKeepsPhotoAnnotations() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let fixture = try makeAnnotatedVillageTrip(in: ctx)
        let tripID = fixture.trip.id

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.demoteSeededTrip(tripID).isDemoted)
        // A CloudKit resurrection lands the trip row before the user taps Undo.
        let resurrected = Trip(startDate: date(day: 0))
        resurrected.id = tripID
        resurrected.endDate = date(day: 0.5)
        resurrected.isComplete = true
        ctx.insert(resurrected)
        try ctx.save()

        await classifier.failNextDissolvedRestoreSave()
        #expect(await classifier.undoLastDemotion() == .failed)
        #expect(try ctx.fetch(FetchDescriptor<HiddenPhoto>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<PinnedPhoto>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<HomeAreaOverride>()).count == 1)

        #expect(await classifier.undoLastDemotion() == .undone)
        try expectOriginalPhotoRows(
            in: ctx, tripID: tripID,
            hiddenID: fixture.hiddenID, pinnedID: fixture.pinnedID)
        #expect(try ctx.fetch(FetchDescriptor<HomeAreaOverride>()).isEmpty)
    }

    @Test("Trip demotion undo onto a trip row that synced back without its stays reattaches them, so assembly mints no second trip")
    func armBUndoReattachesStaysToStaylessReturnedTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let fixture = try makeAnnotatedVillageTrip(in: ctx)
        let second = makeStay(in: ctx, startDay: 0.2, latitude: Self.village.lat,
                              longitude: Self.village.lon, hex: "V")
        fixture.stay.orderInTrip = 0
        second.trip = fixture.trip
        second.orderInTrip = 1
        fixture.trip.customName = "Village Lunch"
        try ctx.save()
        let tripID = fixture.trip.id
        let stayIDs = [fixture.stay.id, second.id]

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.demoteSeededTrip(tripID).isDemoted)
        // CloudKit returns the Trip record without the Stay records that
        // link to it: they are still in flight, or a resurrection re-created
        // only the Trip record while the demote had already unlinked them.
        let returned = Trip(startDate: date(day: 0))
        returned.id = tripID
        returned.endDate = date(day: 0.5)
        returned.isComplete = true
        ctx.insert(returned)
        try ctx.save()
        let returnedRow = returned.persistentModelID

        #expect(await classifier.undoLastDemotion() == .undone)
        // TripsListView.undoDemotion assembles right after the undo.
        #expect(await classifier.assembleTrips() == 0)
        #expect(await classifier.assembledTripsForTesting().map(\.id) == [tripID])
        #expect(await classifier.tripStayIDsForTesting(tripID) == Set(stayIDs))

        let trips = try ctx.fetch(FetchDescriptor<Trip>())
        #expect(trips.map(\.persistentModelID) == [returnedRow])
        let trip = try #require(trips.first)
        #expect(trip.orderedStays.map(\.id) == stayIDs)
        #expect(trip.orderedStays.map(\.orderInTrip) == [0, 1])
        #expect(trip.customName == "Village Lunch", "a name the returned row lacks comes from the record")
        for stay in try ctx.fetch(FetchDescriptor<Stay>()) {
            #expect(stay.category == .destination)
            #expect(!stay.userOverridden)
            #expect(stay.trip?.persistentModelID == returnedRow)
        }
        try expectOriginalPhotoRows(
            in: ctx, tripID: tripID,
            hiddenID: fixture.hiddenID, pinnedID: fixture.pinnedID)
        #expect(try ctx.fetch(FetchDescriptor<HomeAreaOverride>()).isEmpty)
    }

    /// The annotated village trip with a second stay, both ordered.
    private func makeTwoStayVillageTrip(
        in ctx: ModelContext, userEdited: Bool
    ) throws -> (trip: Trip, stayIDs: [UUID], hiddenID: UUID, pinnedID: UUID) {
        let fixture = try makeAnnotatedVillageTrip(in: ctx)
        let second = makeStay(in: ctx, startDay: 0.2, latitude: Self.village.lat,
                              longitude: Self.village.lon, hex: "V")
        fixture.stay.orderInTrip = 0
        second.trip = fixture.trip
        second.orderInTrip = 1
        fixture.trip.userEdited = userEdited
        try ctx.save()
        return (fixture.trip, [fixture.stay.id, second.id], fixture.hiddenID, fixture.pinnedID)
    }

    /// Another device wrote the demoted trip's row and the links of `linked`
    /// stays after the demote; the other stays' links are in flight or lost to
    /// the demote's unlink.
    private func returnTrip(
        _ tripID: UUID, holding linked: [UUID], userEdited: Bool, in ctx: ModelContext
    ) throws -> Trip {
        let returned = Trip(startDate: date(day: 0))
        returned.id = tripID
        returned.endDate = date(day: 0.5)
        returned.isComplete = true
        returned.userEdited = userEdited
        ctx.insert(returned)
        let stays = try ctx.fetch(FetchDescriptor<Stay>())
        for (order, id) in linked.enumerated() {
            let stay = try #require(stays.first { $0.id == id })
            stay.trip = returned
            stay.orderInTrip = order
            stay.category = .destination
            stay.userOverridden = false
        }
        try ctx.save()
        return returned
    }

    @Test("Trip demotion undo onto a trip row that synced back holding some or all of its stays reattaches the rest, so assembly mints no second trip",
          arguments: [false, true], [1, 2])
    func armBUndoReusesReturnedTripHoldingStays(userEdited: Bool, linkedStays: Int) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let fixture = try makeTwoStayVillageTrip(in: ctx, userEdited: userEdited)
        let tripID = fixture.trip.id

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.demoteSeededTrip(tripID).isDemoted)
        let returnedRow = try returnTrip(
            tripID, holding: Array(fixture.stayIDs.prefix(linkedStays)),
            userEdited: userEdited, in: ctx).persistentModelID

        #expect(await classifier.undoLastDemotion() == .undone)
        // TripsListView.undoDemotion assembles right after the undo. An edited
        // trip is never regrouped, and an unedited one would be re-minted, so
        // a stay left unassigned would move to another row.
        #expect(await classifier.assembleTrips() == 0)
        let assembled = await classifier.assembledTripsForTesting()
        #expect(assembled.map(\.id) == [tripID])
        #expect(assembled.first?.orders == [0, 1])
        #expect(await classifier.tripStayIDsForTesting(tripID) == Set(fixture.stayIDs))

        let trips = try ctx.fetch(FetchDescriptor<Trip>())
        #expect(trips.map(\.persistentModelID) == [returnedRow])
        let trip = try #require(trips.first)
        #expect(trip.orderedStays.map(\.id) == fixture.stayIDs)
        #expect(trip.orderedStays.map(\.orderInTrip) == [0, 1])
        #expect(trip.userEdited == userEdited)
        #expect(trip.isComplete)
        #expect(trip.startDate == date(day: 0))
        #expect(trip.endDate == date(day: 0.5))
        for stay in try ctx.fetch(FetchDescriptor<Stay>()) {
            #expect(stay.category == .destination)
            #expect(!stay.userOverridden)
            #expect(stay.trip?.persistentModelID == returnedRow)
        }
        try expectOriginalPhotoRows(
            in: ctx, tripID: tripID,
            hiddenID: fixture.hiddenID, pinnedID: fixture.pinnedID)
        #expect(try ctx.fetch(FetchDescriptor<HomeAreaOverride>()).isEmpty)
    }

    @Test("Trip demotion undo onto a partly returned trip whose unlinked stay has a twin row fails without freeing it and stays retryable")
    func armBUndoOntoPartlyReturnedTripWaitsForStayTwins() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let fixture = try makeTwoStayVillageTrip(in: ctx, userEdited: true)
        let tripID = fixture.trip.id
        let secondID = fixture.stayIDs[1]

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.demoteSeededTrip(tripID).isDemoted)
        let returned = try returnTrip(
            tripID, holding: [fixture.stayIDs[0]], userEdited: true, in: ctx)
        let twin = makeStay(in: ctx, startDay: 0.2, latitude: Self.village.lat,
                            longitude: Self.village.lon, category: .home, hex: "V")
        twin.id = secondID
        try ctx.save()

        #expect(await classifier.undoLastDemotion() == .failed)
        // Neither row of the unlinked stay was freed for assembly to re-mint.
        #expect(await classifier.assembleTrips() == 0)
        for stay in try ctx.fetch(FetchDescriptor<Stay>()) where stay.id == secondID {
            #expect(stay.category == .home)
            #expect(stay.trip == nil)
        }
        #expect(returned.stays?.map(\.id) == [fixture.stayIDs[0]])
        #expect(try ctx.fetch(FetchDescriptor<HiddenPhoto>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<PinnedPhoto>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<HomeAreaOverride>()).count == 1)

        // Once the stay twins converge, the kept undo completes the trip.
        ctx.delete(twin)
        try ctx.save()
        #expect(await classifier.undoLastDemotion() == .undone)
        #expect(await classifier.assembleTrips() == 0)
        let trips = try ctx.fetch(FetchDescriptor<Trip>())
        #expect(trips.map(\.persistentModelID) == [returned.persistentModelID])
        #expect(trips.first?.orderedStays.map(\.id) == fixture.stayIDs)
        try expectOriginalPhotoRows(
            in: ctx, tripID: tripID,
            hiddenID: fixture.hiddenID, pinnedID: fixture.pinnedID)
        #expect(try ctx.fetch(FetchDescriptor<HomeAreaOverride>()).isEmpty)
    }

    /// A stayless returned row's span against the removed trip's.
    enum ReturnedSpan: CaseIterable, Sendable {
        /// A lagging copy of the closed trip that ends before its last stay.
        case staleClosed
        /// A lagging copy from while the closed trip was still open.
        case staleOpen
        /// Another device closed the trip that was still open here.
        case closedElsewhere
        /// Open on both devices.
        case open
    }

    @Test("a trip row that synced back without its stays takes the removed trip's span with them, keeping a closure seen elsewhere",
          arguments: ReturnedSpan.allCases)
    func staylessReturnedTripSpansItsReattachedStays(_ span: ReturnedSpan) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(in: ctx, startDay: -10)
        let closedHere = span == .staleClosed || span == .staleOpen
        let trip = Trip(startDate: date(day: 0))
        ctx.insert(trip)
        let first = makeStay(in: ctx, startDay: 0, latitude: Self.village.lat,
                             longitude: Self.village.lon, hex: "V")
        let second = makeStay(in: ctx, startDay: 1, latitude: Self.village.lat,
                              longitude: Self.village.lon, hex: "V")
        first.trip = trip
        first.orderInTrip = 0
        second.trip = trip
        second.orderInTrip = 1
        trip.isComplete = closedHere
        trip.endDate = closedHere ? second.endTime : nil
        try ctx.save()
        let tripID = trip.id
        let stayIDs: Set<UUID> = [first.id, second.id]
        let lastEnd = second.endTime

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.demoteSeededTrip(tripID).isDemoted)
        let returned = Trip(startDate: date(day: 0.3))
        returned.id = tripID
        if span == .staleClosed || span == .closedElsewhere {
            returned.isComplete = true
            returned.endDate = date(day: 0.5)
        }
        ctx.insert(returned)
        try ctx.save()
        let returnedRow = returned.persistentModelID

        #expect(await classifier.undoLastDemotion() == .undone)
        let trips = try ctx.fetch(FetchDescriptor<Trip>())
        #expect(trips.map(\.persistentModelID) == [returnedRow])
        let restored = try #require(trips.first)
        #expect(Set((restored.stays ?? []).map(\.id)) == stayIDs)
        #expect(restored.startDate == date(day: 0))
        if span == .open {
            #expect(!restored.isComplete)
            #expect(restored.endDate == nil)
        } else {
            #expect(restored.isComplete)
            #expect(restored.endDate == lastEnd, "a closed trip ends with its last stay")
        }

        // The next assembly keeps the identity (an open trip is rebuilt onto its own row).
        #expect(await classifier.assembleTrips() == (span == .open ? 1 : 0))
        #expect(await classifier.assembledTripsForTesting().map(\.id) == [tripID])
        #expect(await classifier.tripStayIDsForTesting(tripID) == stayIDs)
    }

    /// Store states sync can leave between demote and Undo that make an exact restore impossible for now.
    enum DemotedStayDivergence: CaseIterable, Sendable {
        /// A physical twin row shares a member stay's UUID.
        case twinRow
        /// A member stay row is absent.
        case missingStay
        /// A member stay belongs to another trip.
        case claimedStay
    }

    @Test("Trip demotion undo whose stays diverged since the demote fails without freeing them and stays retryable",
          arguments: DemotedStayDivergence.allCases)
    func armBUndoWithDivergedStaysKeepsDemotion(_ divergence: DemotedStayDivergence) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let fixture = try makeAnnotatedVillageTrip(in: ctx)
        let second = makeStay(in: ctx, startDay: 0.2, latitude: Self.village.lat,
                              longitude: Self.village.lon, hex: "V")
        second.trip = fixture.trip
        try ctx.save()
        let tripID = fixture.trip.id
        let firstID = fixture.stay.id
        let secondID = second.id

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.demoteSeededTrip(tripID).isDemoted)

        let demotedSecond = try #require(try ctx.fetch(FetchDescriptor<Stay>())
            .first { $0.id == secondID })
        var twin: Stay?
        var claimant: Trip?
        switch divergence {
        case .twinRow:
            let row = makeStay(in: ctx, startDay: 0, latitude: Self.village.lat,
                               longitude: Self.village.lon, category: .home, hex: "V")
            row.id = firstID
            twin = row
        case .missingStay:
            ctx.delete(demotedSecond)
        case .claimedStay:
            let trip = Trip(startDate: date(day: 0))
            ctx.insert(trip)
            demotedSecond.trip = trip
            claimant = trip
        }
        try ctx.save()
        let twinRowID = twin?.persistentModelID

        #expect(await classifier.undoLastDemotion() == .failed)
        // Nothing was freed or re-minted, and the record keeps the photo rows.
        #expect(try ctx.fetch(FetchDescriptor<Trip>()).allSatisfy { $0.id != tripID })
        #expect(try ctx.fetch(FetchDescriptor<HiddenPhoto>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<PinnedPhoto>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<HomeAreaOverride>()).count == 1)
        for stay in try ctx.fetch(FetchDescriptor<Stay>()) {
            #expect(stay.category == .home)
            #expect(stay.userOverridden == (stay.persistentModelID != twinRowID))
            #expect(stay.trip?.id == (stay.id == secondID ? claimant?.id : nil))
        }
        let parked = await classifier.drainParkedDissolvedTrips()
        #expect(parked.map(\.id) == [tripID])
        #expect(parked.first?.photoAnnotations?.count == 2)

        // Once the store converges, the kept undo reverses the whole demotion.
        switch divergence {
        case .twinRow:
            if let twin { ctx.delete(twin) }
        case .missingStay:
            let returned = makeStay(in: ctx, startDay: 0.2, latitude: Self.village.lat,
                                    longitude: Self.village.lon, category: .home, hex: "V")
            returned.id = secondID
            returned.userOverridden = true
        case .claimedStay:
            demotedSecond.trip = nil
        }
        try ctx.save()

        #expect(await classifier.undoLastDemotion() == .undone)
        #expect(try ctx.fetch(FetchDescriptor<Trip>(
            predicate: #Predicate { $0.id == tripID })).count == 1)
        try expectOriginalPhotoRows(
            in: ctx, tripID: tripID,
            hiddenID: fixture.hiddenID, pinnedID: fixture.pinnedID)
        #expect(try ctx.fetch(FetchDescriptor<HomeAreaOverride>()).isEmpty)
        let stays = try ctx.fetch(FetchDescriptor<Stay>())
        #expect(Set(stays.map(\.id)) == [firstID, secondID])
        #expect(stays.count == 2)
        for stay in stays {
            #expect(stay.category == .destination)
            #expect(!stay.userOverridden)
            #expect(stay.trip?.id == tripID)
        }
    }

    @Test("the demoted trip's parked recovery record restores its photo rows, after a queue round trip and Calendar scrub")
    func demotedTripRecoveryRecordRestoresPhotoAnnotations() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let fixture = try makeAnnotatedVillageTrip(in: ctx)
        fixture.trip.aiGeneratedTitle = "Village Escape"
        try ctx.save()
        let tripID = fixture.trip.id
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("demote-annotation-queue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.demoteSeededTrip(tripID).isDemoted)
        // The undo alert was missed; the queue file is the only copy left.
        try DissolvedTripQueue.append(
            await classifier.drainParkedDissolvedTrips(), in: dir)
        try DissolvedTripQueue.scrubGeneratedTitles(in: dir)
        let record = try #require(DissolvedTripQueue.load(from: dir).first)
        #expect(record.id == tripID)
        #expect(record.aiGeneratedTitle == nil)

        // Removed Trips → Restore.
        #expect(await classifier.restoreDissolvedTrip(
            record, markStaysSacred: true) == .restored)
        try expectOriginalPhotoRows(
            in: ctx, tripID: tripID,
            hiddenID: fixture.hiddenID, pinnedID: fixture.pinnedID)
        // A second restore of the same record adds nothing.
        #expect(await classifier.restoreDissolvedTrip(
            record, markStaysSacred: true) == .alreadyExists)
        try expectOriginalPhotoRows(
            in: ctx, tripID: tripID,
            hiddenID: fixture.hiddenID, pinnedID: fixture.pinnedID)
    }

    /// Paths that prune a queued record once its trip is present again.
    enum ReturnedTripPrune: CaseIterable, Sendable {
        /// Removed Trips → Restore, whose trip came back while the list was open.
        case manualRestore
        /// Auto-rescue after a late-synced favourite.
        case rescue
        /// The Removed Trips list dropping records whose trip is present.
        case listReload
    }

    enum ReturnedTripFailure: CaseIterable, Sendable {
        case stayRead
        case annotationRead
        case save
    }

    /// Run one prune path and report whether it would drop the record.
    private func prunes(
        _ path: ReturnedTripPrune, record: DissolvedTripRecord,
        classifier: TripClassifier
    ) async -> Bool {
        switch path {
        case .manualRestore:
            return await classifier.restoreDissolvedTrip(
                record, markStaysSacred: true) == .alreadyExists
        case .rescue:
            let outcome = await classifier.rescueDissolvedTrips(
                [record], pinnedTripIDs: [record.id])
            #expect(outcome.restored.isEmpty)
            return outcome.prunable == [record.id]
        case .listReload:
            return await classifier.settleReturnedDissolvedTrips([record]) == [record.id]
        }
    }

    @Test("a demoted trip that came back without its photo rows gets them before any path prunes its record",
          arguments: ReturnedTripPrune.allCases, ReturnedTripFailure.allCases)
    func returnedDemotedTripKeepsPhotoAnnotations(
        _ path: ReturnedTripPrune, _ failure: ReturnedTripFailure
    ) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let fixture = try makeAnnotatedVillageTrip(in: ctx)
        let tripID = fixture.trip.id

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.demoteSeededTrip(tripID).isDemoted)
        let record = try #require(await classifier.drainParkedDissolvedTrips().first)
        #expect(record.carriesPhotoAnnotations)
        // The trip row and its stay come back without the photo rows (a
        // CloudKit resurrection or an import) after the undo window closed.
        let returned = Trip(startDate: date(day: 0))
        returned.id = tripID
        returned.endDate = date(day: 0.5)
        returned.isComplete = true
        ctx.insert(returned)
        let stay = try #require(try ctx.fetch(FetchDescriptor<Stay>())
            .first { $0.id == fixture.stay.id })
        stay.trip = returned
        stay.category = .destination
        stay.userOverridden = false
        try ctx.save()

        // A rescue first reads the recorded stays once to check for a stay the
        // user set since; the restore's reads follow it.
        let rescueRead = path == .rescue ? 1 : 0
        switch failure {
        case .stayRead:
            // The trip identity read, then its recorded stays.
            await classifier.failDissolvedRestoreFetchCallForTesting(2 + rescueRead)
        case .annotationRead:
            // The trip identity and recorded stay reads, then the hidden rows
            // keyed to the trip.
            await classifier.failDissolvedRestoreFetchCallForTesting(3 + rescueRead)
        case .save:
            await classifier.failNextDissolvedRestoreSave()
        }
        #expect(await prunes(path, record: record, classifier: classifier) == false)
        #expect(try ctx.fetch(FetchDescriptor<HiddenPhoto>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<PinnedPhoto>()).isEmpty)

        #expect(await prunes(path, record: record, classifier: classifier))
        try expectOriginalPhotoRows(
            in: ctx, tripID: tripID,
            hiddenID: fixture.hiddenID, pinnedID: fixture.pinnedID)
        #expect(try ctx.fetch(FetchDescriptor<Trip>()).count == 1)

        // Pruning again adds nothing.
        #expect(await prunes(path, record: record, classifier: classifier))
        try expectOriginalPhotoRows(
            in: ctx, tripID: tripID,
            hiddenID: fixture.hiddenID, pinnedID: fixture.pinnedID)
    }

    @Test("a removed trip whose row came back without its stays gets them from its record, never a second identity",
          arguments: ReturnedTripPrune.allCases)
    func staylessReturnedTripReattachesRecordedStays(_ path: ReturnedTripPrune) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let fixture = try makeAnnotatedVillageTrip(in: ctx)
        let tripID = fixture.trip.id
        let stayID = fixture.stay.id

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.demoteSeededTrip(tripID).isDemoted)
        let record = try #require(await classifier.drainParkedDissolvedTrips().first)
        // Only the Trip record synced back; its stay is still unlinked.
        let returned = Trip(startDate: date(day: 0))
        returned.id = tripID
        returned.endDate = date(day: 0.5)
        returned.isComplete = true
        ctx.insert(returned)
        try ctx.save()
        let returnedRow = returned.persistentModelID

        switch path {
        case .manualRestore:
            #expect(await classifier.restoreDissolvedTrip(
                record, markStaysSacred: true) == .restored)
        case .rescue:
            let outcome = await classifier.rescueDissolvedTrips(
                [record], pinnedTripIDs: [tripID])
            #expect(outcome.restored == [tripID])
            #expect(outcome.prunable.isEmpty)
        case .listReload:
            // The trip is not back yet, so the list keeps the record for Restore.
            #expect(await classifier.settleReturnedDissolvedTrips([record]).isEmpty)
            #expect(try ctx.fetch(FetchDescriptor<HiddenPhoto>()).isEmpty)
            #expect(try ctx.fetch(FetchDescriptor<PinnedPhoto>()).isEmpty)
            let parked = try #require(try ctx.fetch(FetchDescriptor<Stay>())
                .first { $0.id == stayID })
            #expect(parked.trip == nil)
            #expect(parked.category == .home)
            #expect(await classifier.restoreDissolvedTrip(
                record, markStaysSacred: true) == .restored)
        }
        #expect(await classifier.assembleTrips() == 0)
        #expect(await classifier.tripStayIDsForTesting(tripID) == [stayID])

        #expect(try ctx.fetch(FetchDescriptor<Trip>()).map(\.persistentModelID) == [returnedRow])
        let stay = try #require(try ctx.fetch(FetchDescriptor<Stay>())
            .first { $0.id == stayID })
        #expect(stay.category == .destination)
        #expect(stay.trip?.persistentModelID == returnedRow)
        try expectOriginalPhotoRows(
            in: ctx, tripID: tripID,
            hiddenID: fixture.hiddenID, pinnedID: fixture.pinnedID)
        // Now the trip is back, and every path may prune its record.
        #expect(await prunes(path, record: record, classifier: classifier))
        #expect(try ctx.fetch(FetchDescriptor<Trip>()).count == 1)
    }

    @Test("a removed trip whose row came back with only some of its stays gets the rest from its record, never a second identity",
          arguments: ReturnedTripPrune.allCases)
    func partlyReturnedTripReattachesUnassignedRecordedStays(_ path: ReturnedTripPrune) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let fixture = try makeTwoStayVillageTrip(in: ctx, userEdited: true)
        let tripID = fixture.trip.id
        let firstID = fixture.stayIDs[0]
        let secondID = fixture.stayIDs[1]

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.demoteSeededTrip(tripID).isDemoted)
        let record = try #require(await classifier.drainParkedDissolvedTrips().first)
        let returnedRow = try returnTrip(
            tripID, holding: [firstID], userEdited: true, in: ctx).persistentModelID

        switch path {
        case .manualRestore:
            #expect(await classifier.restoreDissolvedTrip(
                record, markStaysSacred: true) == .restored)
        case .rescue:
            let outcome = await classifier.rescueDissolvedTrips(
                [record], pinnedTripIDs: [tripID])
            #expect(outcome.restored == [tripID])
            #expect(outcome.prunable.isEmpty)
        case .listReload:
            // The trip is not back whole, so the list keeps the record for Restore.
            #expect(await classifier.settleReturnedDissolvedTrips([record]).isEmpty)
            #expect(try ctx.fetch(FetchDescriptor<HiddenPhoto>()).isEmpty)
            #expect(try ctx.fetch(FetchDescriptor<PinnedPhoto>()).isEmpty)
            let parked = try #require(try ctx.fetch(FetchDescriptor<Stay>())
                .first { $0.id == secondID })
            #expect(parked.trip == nil)
            #expect(parked.category == .home)
            #expect(await classifier.restoreDissolvedTrip(
                record, markStaysSacred: true) == .restored)
        }
        // An edited trip is never regrouped: a stay left unassigned would be
        // re-minted under a new UUID here.
        #expect(await classifier.assembleTrips() == 0)
        #expect(await classifier.tripStayIDsForTesting(tripID) == Set(fixture.stayIDs))

        #expect(try ctx.fetch(FetchDescriptor<Trip>()).map(\.persistentModelID) == [returnedRow])
        let stays = try ctx.fetch(FetchDescriptor<Stay>())
        let first = try #require(stays.first { $0.id == firstID })
        let second = try #require(stays.first { $0.id == secondID })
        #expect(first.trip?.persistentModelID == returnedRow)
        #expect(first.orderInTrip == 0)
        #expect(!first.userOverridden, "its own synced stay is left as it came")
        #expect(second.trip?.persistentModelID == returnedRow)
        #expect(second.orderInTrip == 1)
        #expect(second.category == .destination)
        #expect(second.userOverridden, "sacred from the restore or kept from the demote")
        try expectOriginalPhotoRows(
            in: ctx, tripID: tripID,
            hiddenID: fixture.hiddenID, pinnedID: fixture.pinnedID)
        // Now the trip is back whole, and every path may prune its record.
        #expect(await prunes(path, record: record, classifier: classifier))
        #expect(try ctx.fetch(FetchDescriptor<Trip>()).count == 1)
    }

    /// Paths that complete a returned trip from its record.
    enum ReturnedTripCompletion: CaseIterable, Sendable {
        case manualRestore
        case rescue
        case undo
    }

    /// Run one completion path and report whether it restored the trip.
    private func completes(
        _ path: ReturnedTripCompletion, record: DissolvedTripRecord,
        classifier: TripClassifier
    ) async -> Bool {
        switch path {
        case .manualRestore:
            return await classifier.restoreDissolvedTrip(
                record, markStaysSacred: true) == .restored
        case .rescue:
            let outcome = await classifier.rescueDissolvedTrips(
                [record], pinnedTripIDs: [record.id])
            return outcome.restored == [record.id]
        case .undo:
            return await classifier.undoLastDemotion() == .undone
        }
    }

    /// The two-stay village trip titled for its whole membership, with a German
    /// translation and a summary.
    private func makeTitledTwoStayVillageTrip(
        in ctx: ModelContext
    ) throws -> (trip: Trip, stayIDs: [UUID]) {
        let fixture = try makeTwoStayVillageTrip(in: ctx, userEdited: true)
        let revision = UUID()
        fixture.trip.aiGeneratedTitle = "Village Weekend"
        fixture.trip.titleSourceRevision = revision
        fixture.trip.aiGeneratedSummary = "A quiet village weekend."
        fixture.trip.summarySourceRaw = SummarySource.foundationModels.rawValue
        ctx.insert(TripTitleVariant(
            languageTag: "de", title: "Dorfwochenende",
            sourceTitle: "Village Weekend", sourceRevision: revision,
            generationVersion: TripTitleStore.currentGenerationVersion, updatedAt: .now, trip: fixture.trip))
        try ctx.save()
        return (fixture.trip, fixture.stayIDs)
    }

    /// Give a returned row the title, translation and summary another device
    /// generated for the membership it synced with.
    private func titleReturnedRow(
        _ row: Trip, _ title: String, in ctx: ModelContext
    ) throws -> (revision: UUID, variantID: UUID) {
        let revision = UUID()
        row.aiGeneratedTitle = title
        row.titleSourceRevision = revision
        row.aiGeneratedSummary = "A morning in the village."
        row.summaryGeneratedAt = .now
        row.summarySourceRaw = SummarySource.foundationModels.rawValue
        let variant = TripTitleVariant(
            languageTag: "de", title: "Dorfmorgen",
            sourceTitle: title, sourceRevision: revision,
            generationVersion: TripTitleStore.currentGenerationVersion, updatedAt: .now, trip: row)
        ctx.insert(variant)
        try ctx.save()
        return (revision, variant.id)
    }

    private func renameVillage(of stayID: UUID, in ctx: ModelContext) throws {
        let stay = try #require(try ctx.fetch(FetchDescriptor<Stay>())
            .first { $0.id == stayID })
        stay.locality = "Renamed Village"
        try ctx.save()
    }

    @Test("completing a partly returned trip derives its title again and drops the translations its row synced with for other stays",
          arguments: ReturnedTripCompletion.allCases)
    func partlyReturnedTripDropsStaleSyncedArtifacts(_ path: ReturnedTripCompletion) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let fixture = try makeTitledTwoStayVillageTrip(in: ctx)
        let tripID = fixture.trip.id

        let classifier = TripClassifier(modelContainer: container)
        await classifier.setGeneratedTitleRevocationPendingForTesting(false)
        #expect(await classifier.demoteSeededTrip(tripID).isDemoted)
        let record = try #require(await classifier.drainParkedDissolvedTrips().first)
        let returned = try returnTrip(
            tripID, holding: [fixture.stayIDs[0]], userEdited: true, in: ctx)
        _ = try titleReturnedRow(returned, "Village Morning", in: ctx)
        // The recorded title no longer describes the joined stays either.
        try renameVillage(of: fixture.stayIDs[1], in: ctx)

        #expect(await completes(path, record: record, classifier: classifier))
        let trip = try #require(try ctx.fetch(FetchDescriptor<Trip>()).first)
        #expect(Set((trip.stays ?? []).map(\.id)) == Set(fixture.stayIDs))
        #expect(trip.aiGeneratedTitle == "Renamed Village")
        #expect(try ctx.fetchCount(FetchDescriptor<TripTitleVariant>()) == 0)
    }

    @Test("completing a partly returned trip reinstates the removed trip's own title when the joined stays are exactly those it was made for",
          arguments: ReturnedTripCompletion.allCases)
    func partlyReturnedTripTakesRecordedTitle(_ path: ReturnedTripCompletion) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let fixture = try makeTitledTwoStayVillageTrip(in: ctx)
        let tripID = fixture.trip.id

        let classifier = TripClassifier(modelContainer: container)
        await classifier.setGeneratedTitleRevocationPendingForTesting(false)
        #expect(await classifier.demoteSeededTrip(tripID).isDemoted)
        let record = try #require(await classifier.drainParkedDissolvedTrips().first)
        let recordedVariantIDs = Set((record.localizedTitles ?? []).map(\.id))
        #expect(recordedVariantIDs.count == 1)
        let returned = try returnTrip(
            tripID, holding: [fixture.stayIDs[0]], userEdited: true, in: ctx)
        let synced = try titleReturnedRow(returned, "Village Morning", in: ctx)

        #expect(await completes(path, record: record, classifier: classifier))
        let trip = try #require(try ctx.fetch(FetchDescriptor<Trip>()).first)
        #expect(trip.aiGeneratedTitle == "Village Weekend")
        #expect(trip.titleSourceRevision == record.titleSourceRevision)
        #expect(trip.aiGeneratedSummary == "A quiet village weekend.")
        let variants = try ctx.fetch(FetchDescriptor<TripTitleVariant>())
        #expect(Set(variants.map(\.id)) == recordedVariantIDs)
        #expect(!variants.contains { $0.id == synced.variantID })
        #expect(variants.allSatisfy { $0.trip?.id == tripID })
    }

    @Test("completing a partly returned trip keeps a returned title that is the removed trip's own, with every translation")
    func partlyReturnedTripKeepsItsRecordedTitle() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let fixture = try makeTitledTwoStayVillageTrip(in: ctx)
        let tripID = fixture.trip.id

        let classifier = TripClassifier(modelContainer: container)
        await classifier.setGeneratedTitleRevocationPendingForTesting(false)
        #expect(await classifier.demoteSeededTrip(tripID).isDemoted)
        let record = try #require(await classifier.drainParkedDissolvedTrips().first)
        let returned = try returnTrip(
            tripID, holding: [fixture.stayIDs[0]], userEdited: true, in: ctx)
        let synced = try titleReturnedRow(returned, "Village Weekend", in: ctx)
        let french = TripTitleVariant(
            languageTag: "fr", title: "Week-end au village",
            sourceTitle: "Village Weekend", sourceRevision: synced.revision,
            generationVersion: TripTitleStore.currentGenerationVersion, updatedAt: .now, trip: returned)
        ctx.insert(french)
        try ctx.save()
        let frenchID = french.id

        #expect(await classifier.restoreDissolvedTrip(
            record, markStaysSacred: true) == .restored)
        let trip = try #require(try ctx.fetch(FetchDescriptor<Trip>()).first)
        #expect(trip.aiGeneratedTitle == "Village Weekend")
        #expect(trip.titleSourceRevision == synced.revision)
        let variantIDs = try ctx.fetch(FetchDescriptor<TripTitleVariant>()).map(\.id)
        #expect(Set(variantIDs) == [synced.variantID, frenchID])
    }

    @Test("completing a partly returned trip never touches its custom name")
    func partlyReturnedTripKeepsCustomName() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let fixture = try makeTitledTwoStayVillageTrip(in: ctx)
        let tripID = fixture.trip.id

        let classifier = TripClassifier(modelContainer: container)
        await classifier.setGeneratedTitleRevocationPendingForTesting(false)
        #expect(await classifier.demoteSeededTrip(tripID).isDemoted)
        let record = try #require(await classifier.drainParkedDissolvedTrips().first)
        let returned = try returnTrip(
            tripID, holding: [fixture.stayIDs[0]], userEdited: true, in: ctx)
        _ = try titleReturnedRow(returned, "Village Morning", in: ctx)
        returned.customName = "Paris with Mum"
        try ctx.save()

        #expect(await classifier.restoreDissolvedTrip(
            record, markStaysSacred: true) == .restored)
        let trip = try #require(try ctx.fetch(FetchDescriptor<Trip>()).first)
        #expect(trip.customName == "Paris with Mum")
        #expect(trip.displayName == "Paris with Mum")
        #expect(trip.aiGeneratedTitle == nil, "the name is not the record's, so its title is unproven")
    }

    @Test("a stayless returned row takes the removed trip's title for its reattached stays, or a derived one once they changed",
          arguments: [false, true])
    func staylessReturnedTripReplacesSyncedTitle(staysChanged: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let fixture = try makeTitledTwoStayVillageTrip(in: ctx)
        let tripID = fixture.trip.id

        let classifier = TripClassifier(modelContainer: container)
        await classifier.setGeneratedTitleRevocationPendingForTesting(false)
        #expect(await classifier.demoteSeededTrip(tripID).isDemoted)
        let record = try #require(await classifier.drainParkedDissolvedTrips().first)
        let returned = try returnTrip(tripID, holding: [], userEdited: true, in: ctx)
        _ = try titleReturnedRow(returned, "Village Morning", in: ctx)
        if staysChanged { try renameVillage(of: fixture.stayIDs[1], in: ctx) }

        #expect(await classifier.restoreDissolvedTrip(
            record, markStaysSacred: true) == .restored)
        let trip = try #require(try ctx.fetch(FetchDescriptor<Trip>()).first)
        #expect(trip.persistentModelID == returned.persistentModelID)
        #expect(Set((trip.stays ?? []).map(\.id)) == Set(fixture.stayIDs))
        let variantIDs = Set(try ctx.fetch(FetchDescriptor<TripTitleVariant>()).map(\.id))
        if staysChanged {
            #expect(trip.aiGeneratedTitle == "Renamed Village")
            #expect(variantIDs.isEmpty)
        } else {
            #expect(trip.aiGeneratedTitle == "Village Weekend")
            #expect(trip.titleSourceRevision == record.titleSourceRevision)
            #expect(trip.aiGeneratedSummary == "A quiet village weekend.")
            #expect(variantIDs == Set((record.localizedTitles ?? []).map(\.id)))
        }
    }

    @Test("a restore onto a returned row that already holds every stay leaves its title and translations alone")
    func wholeReturnedTripKeepsSyncedTitle() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let fixture = try makeTitledTwoStayVillageTrip(in: ctx)
        let tripID = fixture.trip.id

        let classifier = TripClassifier(modelContainer: container)
        await classifier.setGeneratedTitleRevocationPendingForTesting(false)
        #expect(await classifier.demoteSeededTrip(tripID).isDemoted)
        let record = try #require(await classifier.drainParkedDissolvedTrips().first)
        let returned = try returnTrip(
            tripID, holding: fixture.stayIDs, userEdited: true, in: ctx)
        let synced = try titleReturnedRow(returned, "Village Morning", in: ctx)

        #expect(await classifier.restoreDissolvedTrip(
            record, markStaysSacred: true) == .alreadyExists)
        let trip = try #require(try ctx.fetch(FetchDescriptor<Trip>()).first)
        #expect(trip.aiGeneratedTitle == "Village Morning")
        #expect(trip.titleSourceRevision == synced.revision)
        #expect(trip.aiGeneratedSummary == "A morning in the village.")
        #expect(try ctx.fetch(FetchDescriptor<TripTitleVariant>()).map(\.id) == [synced.variantID])
    }

    @Test("two stayless rows sharing a removed trip's id keep its record until the store converges")
    func twoStaylessReturnedRowsWaitForConvergence() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let fixture = try makeAnnotatedVillageTrip(in: ctx)
        let tripID = fixture.trip.id
        let stayID = fixture.stay.id

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.demoteSeededTrip(tripID).isDemoted)
        let record = try #require(await classifier.drainParkedDissolvedTrips().first)
        var rows: [Trip] = []
        for _ in 0..<2 {
            let row = Trip(startDate: date(day: 0))
            row.id = tripID
            row.endDate = date(day: 0.5)
            row.isComplete = true
            ctx.insert(row)
            rows.append(row)
        }
        try ctx.save()

        #expect(await classifier.restoreDissolvedTrip(
            record, markStaysSacred: true) == .staysAmbiguous)
        #expect(await classifier.settleReturnedDissolvedTrips([record]).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<HiddenPhoto>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<PinnedPhoto>()).isEmpty)
        let parked = try #require(try ctx.fetch(FetchDescriptor<Stay>())
            .first { $0.id == stayID })
        #expect(parked.trip == nil)
        #expect(parked.category == .home)

        // The ghost sweep removes one empty twin; the restore then reattaches.
        ctx.delete(rows[0])
        try ctx.save()
        #expect(await classifier.restoreDissolvedTrip(
            record, markStaysSacred: true) == .restored)
        let trips = try ctx.fetch(FetchDescriptor<Trip>())
        #expect(trips.map(\.persistentModelID) == [rows[1].persistentModelID])
        #expect(trips.first?.stays?.map(\.id) == [stayID])
        try expectOriginalPhotoRows(
            in: ctx, tripID: tripID,
            hiddenID: fixture.hiddenID, pinnedID: fixture.pinnedID)
    }

    @Test("the Removed Trips settle never re-mints a trip that is gone")
    func settleSkipsAbsentTrips() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let fixture = try makeAnnotatedVillageTrip(in: ctx)
        let tripID = fixture.trip.id

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.demoteSeededTrip(tripID).isDemoted)
        let record = try #require(await classifier.drainParkedDissolvedTrips().first)

        #expect(await classifier.settleReturnedDissolvedTrips([record]).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<Trip>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<HiddenPhoto>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<PinnedPhoto>()).isEmpty)
        try expectStillDemoted(in: ctx, stayID: fixture.stay.id)
    }

    @Test("demoting a trip that came back without its photo rows keeps them in the replacing queue record")
    func redemotedReturnedTripKeepsQueuedPhotoAnnotations() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let fixture = try makeAnnotatedVillageTrip(in: ctx)
        let tripID = fixture.trip.id
        let stayID = fixture.stay.id
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("redemote-annotation-queue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let classifier = TripClassifier(modelContainer: container)
        await classifier.setDissolvedRecordSink { records in
            try DissolvedTripQueue.append(records, in: dir)
        }
        #expect(await classifier.demoteSeededTrip(tripID).isDemoted)
        #expect(DissolvedTripQueue.load(from: dir).first?.photoAnnotations?.count == 2)

        // An import brings the trip and its stay back, but not its photo
        // rows, and the user removes it again before the list settles it.
        let returned = Trip(startDate: date(day: 0))
        returned.id = tripID
        returned.endDate = date(day: 0.5)
        returned.isComplete = true
        ctx.insert(returned)
        let stay = try #require(try ctx.fetch(FetchDescriptor<Stay>())
            .first { $0.id == stayID })
        stay.trip = returned
        stay.category = .destination
        stay.userOverridden = false
        try ctx.save()
        #expect(await classifier.demoteSeededTrip(tripID).isDemoted)

        let queued = DissolvedTripQueue.load(from: dir)
        #expect(queued.map(\.id) == [tripID])
        let record = try #require(queued.first)
        #expect(record.photoAnnotations?.count == 2)

        // Removed Trips → Restore brings back the original photo rows.
        #expect(await classifier.restoreDissolvedTrip(
            record, markStaysSacred: true) == .restored)
        try expectOriginalPhotoRows(
            in: ctx, tripID: tripID,
            hiddenID: fixture.hiddenID, pinnedID: fixture.pinnedID)
    }

    @Test("Trip demotion undo frees the siblings healing dissolved in between")
    func undoFreesHealedSiblings() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(in: ctx, startDay: -10)
        func villageTrip(startDay: Double) -> Trip {
            let trip = Trip(startDate: date(day: startDay))
            trip.endDate = date(day: startDay + 0.5)
            trip.isComplete = true
            ctx.insert(trip)
            let stay = makeStay(in: ctx, startDay: startDay,
                                latitude: Self.village.lat,
                                longitude: Self.village.lon, hex: "V")
            stay.trip = trip
            return trip
        }
        let demoted = villageTrip(startDay: 0)
        let sibling = villageTrip(startDay: 20)
        try ctx.save()
        let siblingStayIDs = Set((sibling.stays ?? []).map(\.id))

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        _ = await classifier.demoteSeededTrip(demoted.id)
        // The demote's healIfNeeded dissolves the non-interacted sibling…
        #expect((await classifier.healHomeAreaCorrections(
            pinnedTripIDs: [])).moved == 1)
        // …and the production pipeline pass re-stamps its freed stays
        // `.home` (membership claims them); simulate that re-stamp.
        for stay in try ctx.fetch(FetchDescriptor<Stay>())
        where siblingStayIDs.contains(stay.id) {
            stay.category = .home
        }
        try ctx.save()

        // Undo must free the sibling's stays too; a bare override-row
        // delete left them stamped home forever with no recovery path.
        #expect(await classifier.undoLastDemotion() == .undone)
        for stay in try ctx.fetch(FetchDescriptor<Stay>())
        where siblingStayIDs.contains(stay.id) {
            #expect(stay.category == .unclassified)
            #expect(!stay.userOverridden)
        }
    }

    @Test("Trip demotion undo's sweep of Removed Trips never brings back an earlier demoted trip, and prunes the undone trip's own record")
    func undoSweepKeepsEarlierDemotion() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(in: ctx, startDay: -10)
        func oneStayTrip(startDay: Double, latitude: Double, longitude: Double, hex: String) -> Trip {
            let trip = Trip(startDate: date(day: startDay))
            trip.endDate = date(day: startDay + 0.5)
            trip.isComplete = true
            ctx.insert(trip)
            let stay = makeStay(in: ctx, startDay: startDay, latitude: latitude,
                                longitude: longitude, hex: hex)
            stay.trip = trip
            stay.orderInTrip = 0
            return trip
        }
        // Two places ~11 km apart, so the undone trip's taught disc never reaches the earlier one's stays.
        let earlier = oneStayTrip(startDay: 0, latitude: Self.village.lat, longitude: Self.village.lon, hex: "V")
        let undone = oneStayTrip(startDay: 20, latitude: 37.9320, longitude: 23.9161, hex: "W")
        try ctx.save()
        let earlierID = earlier.id
        let undoneID = undone.id
        let earlierStayIDs = Set((earlier.stays ?? []).map(\.id))

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.demoteSeededTrip(earlierID).isDemoted)
        let earlierRecord = try #require(
            await classifier.drainParkedDissolvedTrips().first { $0.id == earlierID })
        #expect(await classifier.demoteSeededTrip(undoneID).isDemoted)
        let undoneRecord = try #require(
            await classifier.drainParkedDissolvedTrips().first { $0.id == undoneID })
        #expect(await classifier.undoLastDemotion() == .undone)

        // The undo's sweep over the whole queue, in queue order; nil leaves a record queued.
        let earlierOutcome = await classifier.restoreFreedSibling(earlierRecord)
        let undoneOutcome = await classifier.restoreFreedSibling(undoneRecord)
        #expect(earlierOutcome == nil, "the earlier demotion's record stays queued")
        #expect(undoneOutcome == .alreadyExists, "the undone trip is back, so its own record prunes")

        let check = ModelContext(container)
        #expect(try check.fetch(FetchDescriptor<Trip>()).map(\.id) == [undoneID])
        for stay in try check.fetch(FetchDescriptor<Stay>()) where earlierStayIDs.contains(stay.id) {
            #expect(stay.category == .home)
            #expect(stay.userOverridden)
            #expect(stay.trip == nil)
        }
    }

    @Test("a sibling restored in the undo unit is summarized against the stays that unit freed, not an earlier restore's home places")
    func undoRestoredSiblingSummaryReadsFreedHomePlaces() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let home = makeHome(in: ctx, startDay: -10)
        home.locality = "TestCity"
        let demoted = Trip(startDate: date(day: 0))
        demoted.endDate = date(day: 0.5)
        demoted.isComplete = true
        ctx.insert(demoted)
        let demotedStay = makeStay(in: ctx, startDay: 0, latitude: Self.village.lat,
                                   longitude: Self.village.lon, hex: "V", locality: "Villageton")
        demotedStay.trip = demoted
        demotedStay.orderInTrip = 0
        let farStay = makeStay(in: ctx, startDay: 0.2, latitude: 37.57,
                               longitude: 22.8, hex: "N", locality: "Nafplio")
        farStay.trip = demoted
        farStay.orderInTrip = 1
        let sibling = Trip(startDate: date(day: 20))
        sibling.endDate = date(day: 20.5)
        sibling.isComplete = true
        ctx.insert(sibling)
        let villageStay = makeStay(in: ctx, startDay: 20, latitude: Self.village.lat,
                                   longitude: Self.village.lon, hex: "V", locality: "Villageton")
        villageStay.trip = sibling
        villageStay.orderInTrip = 0
        let homeNamedStay = makeStay(in: ctx, startDay: 20.2, latitude: Self.home.lat,
                                     longitude: Self.home.lon, hex: "P", locality: "TestCity")
        homeNamedStay.trip = sibling
        homeNamedStay.orderInTrip = 1
        try ctx.save()
        let demotedID = demoted.id
        let siblingID = sibling.id
        let siblingStayIDs: Set<UUID> = [villageStay.id, homeNamedStay.id]

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        _ = await classifier.demoteSeededTrip(demoted.id)
        #expect((await classifier.healHomeAreaCorrections(
            pinnedTripIDs: [])).moved == 1)
        let siblingRecord = try #require(
            await classifier.drainParkedDissolvedTrips().first { $0.id == siblingID })
        for stay in try ctx.fetch(FetchDescriptor<Stay>())
        where siblingStayIDs.contains(stay.id) {
            stay.category = .home
        }
        try ctx.save()

        // The undo unit's order: the demoted trip's restore reads the index
        // while the sibling's stays are still home, then the override
        // removal frees them, then the sibling is restored.
        TripTitleStore.invalidateHomePlaceIndex()
        #expect(await classifier.undoLastDemotion() == .undone)
        #expect(await classifier.restoreDissolvedTrip(
            siblingRecord, markStaysSacred: false) == .restored)

        let restored = try #require(try ModelContext(container).fetch(
            FetchDescriptor<Trip>(predicate: #Predicate { $0.id == siblingID })).first)
        #expect(restored.destinationSummary == "Villageton")
        // The undone trip's own restore read the index before the removals
        // freed the sibling's stays; the undo re-derives its summary after them.
        let undone = try #require(try ModelContext(container).fetch(
            FetchDescriptor<Trip>(predicate: #Predicate { $0.id == demotedID })).first)
        #expect(undone.destinationSummary.contains("Villageton"))
    }

    @Test("a returned sibling completed after the undo is summarized against its restored categories, not an earlier snapshot")
    func undoReturnedSiblingSummaryReadsRestoredCategories() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let home = makeHome(in: ctx, startDay: -10)
        home.locality = "TestCity"
        let demoted = Trip(startDate: date(day: 0))
        demoted.endDate = date(day: 0.5)
        demoted.isComplete = true
        ctx.insert(demoted)
        let demotedStay = makeStay(in: ctx, startDay: 0, latitude: Self.village.lat,
                                   longitude: Self.village.lon, hex: "V", locality: "Villageton")
        demotedStay.trip = demoted
        let sibling = Trip(startDate: date(day: 20))
        sibling.endDate = date(day: 20.5)
        sibling.isComplete = true
        ctx.insert(sibling)
        let villageStay = makeStay(in: ctx, startDay: 20, latitude: Self.village.lat,
                                   longitude: Self.village.lon, hex: "V", locality: "Villageton")
        villageStay.trip = sibling
        villageStay.orderInTrip = 0
        let homeNamedStay = makeStay(in: ctx, startDay: 20.2, latitude: Self.home.lat,
                                     longitude: Self.home.lon, hex: "P", locality: "TestCity")
        homeNamedStay.trip = sibling
        homeNamedStay.orderInTrip = 1
        try ctx.save()
        let siblingID = sibling.id
        let villageStayID = villageStay.id
        let homeNamedStayID = homeNamedStay.id

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        _ = await classifier.demoteSeededTrip(demoted.id)
        #expect((await classifier.healHomeAreaCorrections(
            pinnedTripIDs: [])).moved == 1)
        let siblingRecord = try #require(
            await classifier.drainParkedDissolvedTrips().first { $0.id == siblingID })
        #expect(await classifier.undoLastDemotion() == .undone)

        // The sibling's row syncs back holding one of its stays, and the other
        // is stamped home, so the restore goes through completeReturnedTrip.
        let returned = Trip(startDate: date(day: 20))
        returned.id = siblingID
        returned.endDate = date(day: 20.5)
        returned.isComplete = true
        ctx.insert(returned)
        for stay in try ctx.fetch(FetchDescriptor<Stay>()) {
            if stay.id == homeNamedStayID {
                stay.trip = returned
                stay.category = .destination
                stay.userOverridden = false
            } else if stay.id == villageStayID {
                stay.category = .home
            }
        }
        try ctx.save()
        // A snapshot filled while the stay is still home, before the restore
        // puts back its recorded category.
        TripTitleStore.invalidateHomePlaceIndex()
        #expect(try TripTitleStore.homePlaceNames(
            tripStart: date(day: 20), tripEnd: date(day: 20.5), in: ctx).contains("villageton"))

        #expect(await classifier.restoreDissolvedTrip(
            siblingRecord, markStaysSacred: false) == .restored)

        let restored = try #require(try ModelContext(container).fetch(
            FetchDescriptor<Trip>(predicate: #Predicate { $0.id == siblingID })).first)
        #expect(restored.destinationSummary == "Villageton")
    }

    @Test("removing an include override frees the user-overridden home stays it created (undo-alert-missed recovery)")
    func removeIncludeFreesSacredStays() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(in: ctx, startDay: -10)
        let trip = Trip(startDate: date(day: 0))
        trip.endDate = date(day: 0.5)
        trip.isComplete = true
        ctx.insert(trip)
        let a = makeStay(in: ctx, startDay: 0, latitude: Self.village.lat,
                         longitude: Self.village.lon, hex: "V")
        a.trip = trip
        try ctx.save()
        let stayID = a.id

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        _ = await classifier.demoteSeededTrip(trip.id)
        let row = try #require(try ctx.fetch(
            FetchDescriptor<HomeAreaOverride>()).first)

        // Home Area Places → Remove: the mistaken teaching is withdrawn,
        // and the stays IT made sacred return to pipeline custody.
        #expect(await classifier.removeOverride(id: row.id))
        let freed = try #require(try ctx.fetch(FetchDescriptor<Stay>())
            .first { $0.id == stayID })
        #expect(freed.category == .unclassified)
        #expect(!freed.userOverridden)
    }

    @Test("the shrink arm: evidence removal de-qualifies a disc, and the stale-coverage snapshot frees the stays it had claimed")
    func evidenceRemovalFreesStrandedHomeStays() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(in: ctx, startDay: -10)
        // The qualifying pattern (same fixture as orbitRolloutIsOnBehaviorally).
        var evidenceIDs: [UUID] = []
        for (i, month) in [0.0, 30, 60].enumerated() {
            makeStay(in: ctx, startDay: month, durationHours: 8,
                     latitude: Self.home.lat, longitude: Self.home.lon,
                     category: .home, hex: "H\(i)")
            let visit = makeStay(in: ctx, startDay: month + 0.4, durationHours: 5,
                                 latitude: Self.village.lat, longitude: Self.village.lon,
                                 hex: "V\(i)")
            evidenceIDs.append(visit.id)
            makeStay(in: ctx, startDay: month + 0.7, durationHours: 10,
                     latitude: Self.home.lat, longitude: Self.home.lon,
                     category: .home, hex: "G\(i)")
        }
        // A stay the LIVE disc claimed `.home` (a healed twin's residue).
        let claimed = makeStay(in: ctx, startDay: 45, durationHours: 3,
                               latitude: Self.village.lat,
                               longitude: Self.village.lon,
                               category: .home, hex: "C")
        try ctx.save()
        let claimedID = claimed.id

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        #expect(await classifier.learnedPlaces().count == 1)

        // The previous heal pass would have snapshotted this coverage.
        let staleCoverage = try await classifier.homeAreaCoverage()
        #expect(!staleCoverage.isEmpty)

        // The user deletes the trip that held the pattern's visits; the
        // cascade erases the evidence stays.
        for stay in try ctx.fetch(FetchDescriptor<Stay>())
        where evidenceIDs.contains(stay.id) {
            ctx.delete(stay)
        }
        try ctx.save()

        // Healing's shrink arm: the disc de-qualifies on re-prime, and the
        // stale snapshot's footprint frees the stay it had claimed.
        _ = await classifier.homeAreaFingerprint() // re-prime post-deletion
        let moved = await classifier.healHomeAreaCorrections(
            pinnedTripIDs: [], staleCoverage: staleCoverage)
        #expect(moved.moved == 1)
        #expect(await classifier.learnedPlaces().isEmpty)
        let stay = try #require(try ctx.fetch(FetchDescriptor<Stay>())
            .first { $0.id == claimedID })
        #expect(stay.category == .unclassified)
    }

    // MARK: - Home-area correction boundaries

    @Test("pre-history stays are matched by seed + valid discs only; a taught include never reaches back before every home")
    func prehistoryIgnoresTaughtIncludes() {
        let membership = HomeMembership(
            seed: Self.squareShape(),
            includeDiscs: [(latitude: Self.village.lat,
                            longitude: Self.village.lon, radiusKm: 1)])
        let ring = TripClassifier.HomeRing(
            latitude: Self.home.lat, longitude: Self.home.lon, radiusKm: 25,
            startedAt: date(day: 0), endedAt: nil, homeID: UUID(),
            membership: membership)
        // In-era: the include claims the village.
        #expect(TripClassifier.matchesHome(
            stayStart: date(day: 10), latitude: Self.village.lat,
            longitude: Self.village.lon, homes: [ring]))
        // Pre-history (predates every home row): it must not.
        #expect(!TripClassifier.matchesHome(
            stayStart: date(day: -400), latitude: Self.village.lat,
            longitude: Self.village.lon, homes: [ring]))
        // …while the seed itself still claims pre-history (load-bearing for
        // imported history; the original fallback contract).
        #expect(TripClassifier.matchesHome(
            stayStart: date(day: -400), latitude: Self.home.lat,
            longitude: Self.home.lon, homes: [ring]))
    }

    @Test("an orbit disc's validity is clamped to its home's era")
    func discValidityClampsToEra() throws {
        let disc = HomeOrbit.OrbitDisc(
            centerLatitude: Self.village.lat, centerLongitude: Self.village.lon,
            radiusKm: 1,
            validity: [DateInterval(start: date(day: 0), end: date(day: 400))],
            returnTimes: [date(day: 0), date(day: 15), date(day: 30)])
        let clamped = try #require(disc.clamped(
            toEra: DateInterval(start: date(day: -10), end: date(day: 60))))
        #expect(clamped.validity == [DateInterval(start: date(day: 0),
                                                  end: date(day: 60))])
        // An era that ended before the pattern began keeps nothing.
        #expect(disc.clamped(
            toEra: DateInterval(start: date(day: -100), end: date(day: -50))) == nil)
    }

    @Test("Welcome-Home gates on the SEED: a taught place is home-area but not a homecoming")
    func welcomeHomeIsSeedOnly() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let home = makeHome(in: ctx, startDay: -10)
        ctx.insert(HomeAreaOverride(
            kind: .include, centerLatitude: Self.village.lat,
            centerLongitude: Self.village.lon, radiusKm: 1, homeID: home.id))
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        // Classification claims the taught village…
        #expect(await classifier.currentMembershipCovers(
            latitude: Self.village.lat, longitude: Self.village.lon))
        // …but arriving there is not a homecoming.
        #expect(try await classifier.currentHomeSeedCovers(
            latitude: Self.village.lat, longitude: Self.village.lon) == false)
        #expect(try await classifier.currentHomeSeedCovers(
            latitude: Self.home.lat, longitude: Self.home.lon))
    }

    @Test("residue current membership claims never reaches the Near-Home review list")
    func suppressedGroupsHideMembershipClaimedResidue() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let home = makeHome(in: ctx, startDay: -10)
        ctx.insert(HomeAreaOverride(
            kind: .include, centerLatitude: Self.village.lat,
            centerLongitude: Self.village.lon, radiusKm: 1, homeID: home.id))
        // Claimed residue (at the taught village) and genuine residue
        // (unclaimed spot beyond the seed).
        makeStay(in: ctx, startDay: 0, latitude: Self.village.lat,
                 longitude: Self.village.lon, hex: "V")
        makeStay(in: ctx, startDay: 2, latitude: 38.0320, longitude: 23.8561,
                 hex: "E", locality: "Errandville")
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        let groups = await classifier.suppressedGroups()
        #expect(groups.count == 1)
        #expect(groups.first?.placeName == "Errandville")
    }

    // MARK: - The orbit rollout, pinned behaviorally

    @Test("the orbit is LIVE: a same-day pattern attaches a learned disc through withShapes")
    func orbitRolloutIsOnBehaviorally() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let home = makeHome(in: ctx, startDay: -10)
        // Three monthly same-day 5 h visits to the village; the measured
        // qualifying pattern (clauses a–d all satisfied, K = 3).
        for (i, month) in [0.0, 30, 60].enumerated() {
            makeStay(in: ctx, startDay: month, durationHours: 8,
                     latitude: Self.home.lat, longitude: Self.home.lon,
                     category: .home, hex: "H\(i)")
            makeStay(in: ctx, startDay: month + 0.4, durationHours: 5,
                     latitude: Self.village.lat, longitude: Self.village.lon,
                     hex: "V\(i)")
            makeStay(in: ctx, startDay: month + 0.7, durationHours: 10,
                     latitude: Self.home.lat, longitude: Self.home.lon,
                     category: .home, hex: "G\(i)")
        }
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        let places = await classifier.learnedPlaces()
        #expect(places.count == 1)
        #expect(places.first?.returnCount == 3)

        let rings = await classifier.withShapes([TripClassifier.HomeRing(
            latitude: Self.home.lat, longitude: Self.home.lon, radiusKm: 25,
            startedAt: date(day: -10), endedAt: nil, homeID: home.id)])
        let membership = try #require(rings.first?.membership)
        #expect(membership.orbitDiscs.count == 1)
        // The disc claims the village AT the pattern's time…
        #expect(membership.contains(latitude: Self.village.lat,
                                    longitude: Self.village.lon,
                                    at: date(day: 30)))
        // …and not two years later (forgetting: the 12-month window).
        #expect(!membership.contains(latitude: Self.village.lat,
                                     longitude: Self.village.lon,
                                     at: date(day: 800)))
    }

    @Test("the first pass judges tripless visits against a learned disc when Stage 1 had nothing to judge",
          IsolatedTitleDefaults(), arguments: [false, true])
    func assemblyReadsCurrentOrbitsWithoutStageOne(excluded: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let home = makeHome(in: ctx, startDay: -10)
        // Every stay is already classified, so Stage 1 has nothing to judge
        // and assembly is the pass's first orbit reader.
        for (i, month) in [0.0, 30, 60].enumerated() {
            makeStay(in: ctx, startDay: month, durationHours: 8,
                     latitude: Self.home.lat, longitude: Self.home.lon,
                     category: .home, hex: "H\(i)")
            makeStay(in: ctx, startDay: month + 0.4, durationHours: 5,
                     latitude: Self.village.lat, longitude: Self.village.lon,
                     hex: "V\(i)")
            makeStay(in: ctx, startDay: month + 0.7, durationHours: 10,
                     latitude: Self.home.lat, longitude: Self.home.lon,
                     category: .home, hex: "G\(i)")
        }
        if excluded {
            // Control: without the disc, 5 h about 12 km beyond the seed
            // scores about 2.1 and clears θ = 2.
            ctx.insert(HomeAreaOverride(
                kind: .exclude, centerLatitude: Self.village.lat,
                centerLongitude: Self.village.lon, radiusKm: 1, homeID: home.id))
        }
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        _ = await classifier.classifyAndAssembleTripsReportingChangesWithGates(
            reclassifyRecentStays: false, gate: PipelineGate(forTesting: ()))

        let villageInTrip = try ModelContext(container).fetch(FetchDescriptor<Stay>())
            .contains { $0.centroidLongitude == Self.village.lon && $0.trip != nil }
        #expect(villageInTrip == excluded)
    }

    @Test("residue a qualifying orbit claims never reaches the Near-Home list, even before any prime")
    func suppressedGroupsPrimeTheirOwnOrbits() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(in: ctx, startDay: -10)
        for (i, month) in [0.0, 30, 60].enumerated() {
            makeStay(in: ctx, startDay: month, durationHours: 8,
                     latitude: Self.home.lat, longitude: Self.home.lon,
                     category: .home, hex: "H\(i)")
            makeStay(in: ctx, startDay: month + 0.4, durationHours: 5,
                     latitude: Self.village.lat, longitude: Self.village.lon,
                     hex: "V\(i)")
            makeStay(in: ctx, startDay: month + 0.7, durationHours: 10,
                     latitude: Self.home.lat, longitude: Self.home.lon,
                     category: .home, hex: "G\(i)")
        }
        // Genuine unclaimed residue, so an empty list cannot pass.
        makeStay(in: ctx, startDay: 2, latitude: 38.0320, longitude: 23.8561,
                 hex: "E", locality: "Errandville")
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        let groups = await classifier.suppressedGroups()
        #expect(groups.count == 1)
        #expect(groups.first?.placeName == "Errandville")
    }

    @Test("excluding a learned place bars it from re-qualifying")
    func excludeLearnedPlaceBarsRequalification() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(in: ctx, startDay: -10)
        for (i, month) in [0.0, 30, 60].enumerated() {
            makeStay(in: ctx, startDay: month, durationHours: 8,
                     latitude: Self.home.lat, longitude: Self.home.lon,
                     category: .home, hex: "H\(i)")
            makeStay(in: ctx, startDay: month + 0.4, durationHours: 5,
                     latitude: Self.village.lat, longitude: Self.village.lon,
                     hex: "V\(i)")
            makeStay(in: ctx, startDay: month + 0.7, durationHours: 10,
                     latitude: Self.home.lat, longitude: Self.home.lon,
                     category: .home, hex: "G\(i)")
        }
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        let place = try #require(await classifier.learnedPlaces().first)
        await classifier.excludeLearnedPlace(place)
        // Idempotent: a second exclude folds into the first row.
        await classifier.excludeLearnedPlace(place)
        #expect(try ctx.fetch(FetchDescriptor<HomeAreaOverride>()).count == 1)
        #expect(await classifier.learnedPlaces().isEmpty)
    }

    @Test("Trip demotion folds into an identical synced override instead of duplicating")
    func armBChecksBeforeInsert() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let home = makeHome(in: ctx, startDay: -10)
        // The same correction already synced from the other device.
        let synced = HomeAreaOverride(
            kind: .include, centerLatitude: Self.village.lat,
            centerLongitude: Self.village.lon, radiusKm: 1, homeID: home.id)
        ctx.insert(synced)
        let trip = Trip(startDate: date(day: 0))
        trip.endDate = date(day: 0.5)
        trip.isComplete = true
        ctx.insert(trip)
        let a = makeStay(in: ctx, startDay: 0, latitude: Self.village.lat,
                         longitude: Self.village.lon, hex: "V")
        a.trip = trip
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        _ = await classifier.demoteSeededTrip(trip.id)
        #expect(try ctx.fetch(FetchDescriptor<HomeAreaOverride>()).count == 1)
    }

    // MARK: - Demotion reads and physical identity

    /// An untouched completed trip with one village stay.
    private func makeDemotionTrip(in ctx: ModelContext, startDay: Double) -> Trip {
        let trip = Trip(startDate: date(day: startDay))
        trip.endDate = date(day: startDay + 0.5)
        trip.isComplete = true
        ctx.insert(trip)
        let stay = makeStay(in: ctx, startDay: startDay, latitude: Self.village.lat,
                            longitude: Self.village.lon, hex: "V")
        stay.trip = trip
        stay.orderInTrip = 0
        return trip
    }

    @Test("a failed trip, Home or override read demotes nothing and teaches no all-era include",
          arguments: ["trip", "home", "override"])
    func demotionFailedReadMutatesNothing(read: String) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let former = makeHome(in: ctx, startDay: -400)
        former.endedAt = date(day: -100)
        let current = makeHome(in: ctx, startDay: -100)
        _ = makeDemotionTrip(in: ctx, startDay: -200)
        let trip = makeDemotionTrip(in: ctx, startDay: 0)
        trip.customName = "Village Errand"
        try ctx.save()
        let tripID = trip.id
        let currentHomeID = current.id

        let classifier = TripClassifier(modelContainer: container)
        switch read {
        case "trip": classifier.failDemotionTripReadForTesting = true
        case "home": classifier.failHomeReadForTesting = true
        default: classifier.failDemotionOverrideReadForTesting = true
        }
        #expect(await classifier.demoteSeededTrip(tripID) == .failed)
        #expect(!(await classifier.readFailureContextHasChangesForTesting()),
                "a preflight failure leaves nothing pending")
        #expect(await classifier.drainParkedDissolvedTrips().isEmpty)
        #expect(await classifier.undoLastDemotion() == .unavailable)
        let fresh = ModelContext(container)
        #expect(try fresh.fetch(FetchDescriptor<HomeAreaOverride>()).isEmpty,
                "no nil-home include may be taught from an unreadable Home table")
        #expect(try fresh.fetch(FetchDescriptor<Trip>()).count == 2)
        for stay in try fresh.fetch(FetchDescriptor<Stay>()) {
            #expect(stay.category == .destination)
            #expect(!stay.userOverridden)
            #expect(stay.trip != nil)
        }

        // With the reads healthy the same tap is scoped to its own era.
        classifier.failDemotionTripReadForTesting = false
        classifier.failHomeReadForTesting = false
        classifier.failDemotionOverrideReadForTesting = false
        #expect(await classifier.demoteSeededTrip(tripID) == .demoted(tripName: "Village Errand"))
        let rows = try ModelContext(container).fetch(FetchDescriptor<HomeAreaOverride>())
        #expect(rows.count == 1)
        #expect(rows.first?.homeID == currentHomeID)
    }

    @Test("a successfully read empty Home table still demotes with an unscoped include")
    func demotionWithNoHomeRowsStillTeaches() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = makeDemotionTrip(in: ctx, startDay: 0)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.demoteSeededTrip(trip.id).isDemoted)
        let rows = try ModelContext(container).fetch(FetchDescriptor<HomeAreaOverride>())
        #expect(rows.count == 1)
        #expect(rows.first?.homeID == nil)
    }

    @Test("a failed demotion keeps the earlier demotion's Undo")
    func failedDemotionKeepsEarlierUndo() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(in: ctx, startDay: -10)
        let first = makeDemotionTrip(in: ctx, startDay: 0)
        let second = makeDemotionTrip(in: ctx, startDay: 3)
        try ctx.save()
        let firstID = first.id
        let secondID = second.id

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.demoteSeededTrip(firstID).isDemoted)
        classifier.failHomeReadForTesting = true
        #expect(await classifier.demoteSeededTrip(secondID) == .failed)
        classifier.failHomeReadForTesting = false

        #expect(await classifier.undoLastDemotion() == .undone)
        let trips = try ModelContext(container).fetch(FetchDescriptor<Trip>())
        #expect(Set(trips.map(\.id)) == [firstID, secondID])
    }

    @Test("demotion acts on the tapped UUID twin only", arguments: [false, true])
    func demotionActsOnTappedTwinOnly(emptyTwinFirst: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(in: ctx, startDay: -10)
        let empty = Trip(startDate: date(day: 0))
        empty.endDate = date(day: 0.5)
        empty.isComplete = true
        if emptyTwinFirst { ctx.insert(empty) }
        let populated = makeDemotionTrip(in: ctx, startDay: 0)
        empty.id = populated.id
        if !emptyTwinFirst { ctx.insert(empty) }
        try ctx.save()
        let emptyRow = empty.persistentModelID
        let populatedRow = populated.persistentModelID
        let tripID = populated.id

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.demoteTripToHomeArea(
            tripID: tripID, tripIdentifier: emptyRow) == .unavailable,
            "the empty twin has nothing to teach; its populated twin is not a stand-in")
        var rows = try ModelContext(container).fetch(FetchDescriptor<Trip>())
        #expect(rows.count == 2)
        #expect(try ModelContext(container).fetch(FetchDescriptor<HomeAreaOverride>()).isEmpty)

        #expect(await classifier.demoteTripToHomeArea(
            tripID: tripID, tripIdentifier: populatedRow).isDemoted)
        rows = try ModelContext(container).fetch(FetchDescriptor<Trip>())
        #expect(rows.map(\.persistentModelID) == [emptyRow], "only the tapped row is removed")
    }
}
