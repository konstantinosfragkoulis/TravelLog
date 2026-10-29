//
//  RoutinePlaceChangeSemanticsTests.swift
//  TravelLogTests
//
//  RoutinePlace add/move had no analogue of
//  `applyHomeChange`, so an in-place radius edit never healed: shrinking
//  stranded `.routine` stays outside the ring as `.routine` FOREVER with no
//  path back into trips, and growing left in-ring stays as `.destination`
//  trips forever. Only "Reclassify All" recovered either.
//
//  Modelled on HomeChangeSemanticsTests: hand-built prior state, driven
//  through the deterministic `applyRoutinePlaceChangeCore` seam so Stage 2's
//  FM lane never runs.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

// Serialized: `SettingsView.failRoutineFetchForTesting` is static.
@Suite(.serialized, IsolatedLineageDefaults())
@MainActor
struct RoutinePlaceChangeSemanticsTests {

    private static let day: TimeInterval = 24 * 60 * 60
    private func date(day offset: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: 5_443_200 + offset * Self.day)
    }

    /// The gym: the routine ring's centre.
    private let gym = (lat: 37.9805, lon: 23.6650)
    /// ~1.2 km away - inside a 2 km ring, outside a 500 m one.
    private let nearGym = (lat: 37.9912, lon: 23.6650)

    @discardableResult
    private func makeStay(
        in ctx: ModelContext,
        startDay: Double,
        category: StayCategory,
        coord: (lat: Double, lon: Double),
        userOverridden: Bool = false
    ) -> Stay {
        let start = date(day: startDay)
        let stay = Stay(
            startTime: start,
            endTime: start.addingTimeInterval(3 * 3600),
            centroidLatitude: coord.lat, centroidLongitude: coord.lon,
            h3IndexRes6: "8a2a1072b59ffff", pingCount: 2,
            distanceFromHomeKm: 4, pingIDs: []
        )
        stay.category = category
        stay.userOverridden = userOverridden
        ctx.insert(stay)
        return stay
    }

    @discardableResult
    private func makePlace(
        in ctx: ModelContext,
        coord: (lat: Double, lon: Double),
        radiusMeters: Double,
        startedDay: Double = -10
    ) -> RoutinePlace {
        let place = RoutinePlace(
            label: "Gym",
            latitude: coord.lat,
            longitude: coord.lon,
            radiusMeters: radiusMeters,
            startedAt: date(day: startedDay)
        )
        ctx.insert(place)
        return place
    }

    private func makeCompletedTrip(in ctx: ModelContext, stays: [Stay], startDay: Double) -> Trip {
        let trip = Trip(startDate: date(day: startDay))
        trip.isComplete = true
        trip.endDate = stays.last?.endTime
        ctx.insert(trip)
        for (order, stay) in stays.enumerated() {
            stay.trip = trip
            stay.orderInTrip = order
        }
        return trip
    }

    /// The classifier is a `@ModelActor` with its OWN context, so objects held
    /// by the test's context do not reflect its saves. Re-fetch by ID.
    private func refetch(_ id: UUID, _ container: ModelContainer) throws -> Stay? {
        let predicate = #Predicate<Stay> { $0.id == id }
        return try ModelContext(container).fetch(FetchDescriptor<Stay>(predicate: predicate)).first
    }

    private func refetchTrip(_ id: UUID, _ container: ModelContainer) throws -> Trip? {
        let predicate = #Predicate<Trip> { $0.id == id }
        return try ModelContext(container).fetch(FetchDescriptor<Trip>(predicate: predicate)).first
    }

    // MARK: - The pure predicate

    @Test("matchesRoutine honours the time window at both ends")
    func predicateWindow() {
        let ring = TripClassifier.RoutineRing(
            latitude: gym.lat, longitude: gym.lon, radiusMeters: 500,
            startedAt: date(day: 0), endedAt: date(day: 10)
        )
        #expect(TripClassifier.matchesRoutine(
            stayStart: date(day: 5), latitude: gym.lat, longitude: gym.lon, places: [ring]))
        // Before it started, and after it ended.
        #expect(!TripClassifier.matchesRoutine(
            stayStart: date(day: -1), latitude: gym.lat, longitude: gym.lon, places: [ring]))
        #expect(!TripClassifier.matchesRoutine(
            stayStart: date(day: 11), latitude: gym.lat, longitude: gym.lon, places: [ring]))
    }

    @Test("the current-place fallback needs a current place and a predating stay")
    func predicateFallback() {
        let current = TripClassifier.RoutineRing(
            latitude: gym.lat, longitude: gym.lon, radiusMeters: 500,
            startedAt: date(day: 100), endedAt: nil
        )
        // Predates every record + a current place exists -> matches.
        #expect(TripClassifier.matchesRoutine(
            stayStart: date(day: 0), latitude: gym.lat, longitude: gym.lon, places: [current]))

        // Same shape but the only place is ENDED -> no fallback.
        let ended = TripClassifier.RoutineRing(
            latitude: gym.lat, longitude: gym.lon, radiusMeters: 500,
            startedAt: date(day: 100), endedAt: date(day: 200)
        )
        #expect(!TripClassifier.matchesRoutine(
            stayStart: date(day: 0), latitude: gym.lat, longitude: gym.lon, places: [ended]))
    }

    // MARK: - Reconciliation

    /// Growing the radius: a trip stay now inside the ring must be released so
    /// the next pipeline pass can stamp it `.routine`.
    @Test("a grown ring releases a destination stay that is now inside it")
    func grownRingReleasesDestinationStay() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let place = makePlace(in: ctx, coord: gym, radiusMeters: 2000)
        let inRing = makeStay(in: ctx, startDay: 1, category: .destination, coord: nearGym)
        try ctx.save()

        let reset = await classifier.applyRoutinePlaceChangeCoreForTesting(placeID: place.id).resetCount

        #expect(reset == 1)
        let reloaded = try #require(try refetch(inRing.id, container))
        #expect(reloaded.category == .unclassified)
        #expect(reloaded.trip == nil)
    }

    /// Shrinking the radius: this is the case that had NO path back at all.
    @Test("a shrunk ring unstamps a routine stay left outside it")
    func shrunkRingUnstampsStrandedStay() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // Ring is now 500 m, but the stay 1.2 km away is still `.routine`
        // from when the ring was larger.
        let place = makePlace(in: ctx, coord: gym, radiusMeters: 500)
        let stranded = makeStay(in: ctx, startDay: 1, category: .routine, coord: nearGym)
        try ctx.save()

        let reset = await classifier.applyRoutinePlaceChangeCoreForTesting(placeID: place.id).resetCount

        #expect(reset == 1)
        let reloaded = try #require(try refetch(stranded.id, container))
        #expect(reloaded.category == .unclassified)
    }

    /// The endDate non-copy: a `.routine` stay is never a trip boundary, so
    /// absorbing one must not move the homecoming (contrast the home path).
    @Test("a shrinking trip keeps its endDate; a routine stay is not a boundary")
    func absorbedStayDoesNotMoveTripEnd() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let place = makePlace(in: ctx, coord: gym, radiusMeters: 2000)
        let far = (lat: 39.6628, lon: 20.8612)  // Ioánnina
        let keep = makeStay(in: ctx, startDay: 1, category: .destination, coord: far)
        let absorbed = makeStay(in: ctx, startDay: 2, category: .destination, coord: nearGym)
        let trip = makeCompletedTrip(in: ctx, stays: [keep, absorbed], startDay: 1)
        trip.aiGeneratedTitle = "Ioánnina & Gym"
        ctx.insert(TripTitleVariant(
            languageTag: "el",
            title: "Γιάννενα και Γυμναστήριο",
            sourceTitle: "Ioánnina & Gym",
            trip: trip))
        let originalEnd = trip.endDate
        let tripID = trip.id
        let keepStart = keep.startTime
        try ctx.save()

        _ = await classifier.applyRoutinePlaceChangeCoreForTesting(placeID: place.id).resetCount

        let reloadedStay = try #require(try refetch(absorbed.id, container))
        #expect(reloadedStay.category == .unclassified)
        let reloadedTrip = try #require(try refetchTrip(tripID, container))
        #expect(reloadedTrip.endDate == originalEnd)
        #expect(reloadedTrip.startDate == keepStart)
        #expect(reloadedTrip.aiGeneratedTitle == nil)
        #expect((reloadedTrip.localizedTitles ?? []).isEmpty)
    }

    @Test("a routine-place change detaching a stay from an ongoing trip invalidates its canonical and localized titles")
    func ongoingTripTitleIsInvalidated() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let place = makePlace(in: ctx, coord: gym, radiusMeters: 2000)
        let far = (lat: 39.6628, lon: 20.8612)
        let keep = makeStay(in: ctx, startDay: 1, category: .destination, coord: far)
        let absorbed = makeStay(
            in: ctx, startDay: 2, category: .destination, coord: nearGym)
        let trip = Trip(startDate: keep.startTime)
        ctx.insert(trip)
        for (order, stay) in [keep, absorbed].enumerated() {
            stay.trip = trip
            stay.orderInTrip = order
        }
        trip.aiGeneratedTitle = "Ioánnina & Gym"
        ctx.insert(TripTitleVariant(
            languageTag: "el",
            title: "Γιάννενα και Γυμναστήριο",
            sourceTitle: "Ioánnina & Gym",
            trip: trip))
        let tripID = trip.id
        try ctx.save()

        #expect(await classifier.applyRoutinePlaceChangeCoreForTesting(
            placeID: place.id).resetCount == 1)

        let reloadedTrip = try #require(try refetchTrip(tripID, container))
        #expect(!reloadedTrip.isComplete)
        #expect(reloadedTrip.aiGeneratedTitle == nil)
        #expect((reloadedTrip.localizedTitles ?? []).isEmpty)
    }

    /// A completed trip whose every destination became routine is a ghost -
    /// completed trips are never rebuilt by assembly, so it must be deleted.
    @Test("a fully absorbed completed trip is deleted rather than left as a ghost")
    func fullyAbsorbedTripIsDeleted() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let place = makePlace(in: ctx, coord: gym, radiusMeters: 2000)
        let only = makeStay(in: ctx, startDay: 1, category: .destination, coord: nearGym)
        _ = makeCompletedTrip(in: ctx, stays: [only], startDay: 1)
        try ctx.save()

        _ = await classifier.applyRoutinePlaceChangeCoreForTesting(placeID: place.id).resetCount

        let trips = try ModelContext(container).fetch(FetchDescriptor<Trip>())
        #expect(trips.isEmpty)
    }

    @Test("while the store may be hydrating, a routine stamp leaves a partly synced completed trip whole and stays owed; settled, it reconciles as before")
    func routineStampLeavesPartlySyncedTripWholeWhileHydrating() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let place = makePlace(in: ctx, coord: (lat: 44.3, lon: 12.9), radiusMeters: 2000)
        // The stop by the place is the only stay that synced in; the away
        // destination the summary names has not arrived yet.
        let stop = makeStay(in: ctx, startDay: 1, category: .destination, coord: (lat: 44.31, lon: 12.9))
        stop.locality = "Velmora"
        let trip = makeCompletedTrip(in: ctx, stays: [stop], startDay: 1)
        trip.destinationSummary = "Velmora, Castrel"
        let tripID = trip.id
        let placeID = place.id
        let stopID = stop.id
        try ctx.save()
        #expect(!TripTitleStore.holdsItsNamedStays(trip))

        let hydrating = await TripTitleStore.$storeMayBeHydratingOverride.withValue(true) {
            await classifier.applyRoutinePlaceChangeCoreForTesting(placeID: placeID)
        }
        #expect(hydrating == .deferred(resetCount: 0))
        #expect(!hydrating.isSettled)

        let kept = try #require(try refetchTrip(tripID, container))
        #expect(kept.orderedStays.map(\.id) == [stopID])
        #expect(kept.orderedStays.first?.category == .destination)
        #expect(kept.destinationSummary == "Velmora, Castrel")

        // Once hydration settles, the owed unit runs again and deletes the
        // emptied row as before.
        let settled = await TripTitleStore.$storeMayBeHydratingOverride.withValue(false) {
            await classifier.applyRoutinePlaceChangeCoreForTesting(placeID: placeID)
        }
        #expect(settled == .committed(resetCount: 1))
        #expect(try refetchTrip(tripID, container) == nil)
        let reloaded = try #require(try refetch(stopID, container))
        #expect(reloaded.category == .unclassified)
        #expect(reloaded.trip == nil)
    }

    @Test("while the store may be hydrating, a routine stamp still shrinks a completed trip that holds every place its summary names")
    func routineStampShrinksFullySyncedTripWhileHydrating() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let place = makePlace(in: ctx, coord: (lat: 44.3, lon: 12.9), radiusMeters: 2000)
        // Judged after the detach, this trip would no longer give "Velmora"
        // and would wrongly wait: it is judged on its stays before it.
        let away = makeStay(in: ctx, startDay: 1, category: .destination, coord: (lat: 44.6, lon: 12.9))
        away.locality = "Castrel"
        let stop = makeStay(in: ctx, startDay: 2, category: .destination, coord: (lat: 44.31, lon: 12.9))
        stop.locality = "Velmora"
        let trip = makeCompletedTrip(in: ctx, stays: [away, stop], startDay: 1)
        trip.destinationSummary = "Castrel, Velmora"
        let tripID = trip.id
        let placeID = place.id
        let awayID = away.id
        try ctx.save()
        #expect(TripTitleStore.holdsItsNamedStays(trip))

        let outcome = await TripTitleStore.$storeMayBeHydratingOverride.withValue(true) {
            await classifier.applyRoutinePlaceChangeCoreForTesting(placeID: placeID)
        }
        #expect(outcome == .committed(resetCount: 1))

        let saved = try #require(try refetchTrip(tripID, container))
        #expect(saved.orderedStays.map(\.id) == [awayID])
        #expect(saved.destinationSummary == "Castrel")
    }

    @Test("user-overridden stays are never touched in either direction")
    func sacredStaysAreUntouched() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let place = makePlace(in: ctx, coord: gym, radiusMeters: 2000)
        let overridden = makeStay(
            in: ctx, startDay: 1, category: .destination, coord: nearGym, userOverridden: true
        )
        try ctx.save()

        // A failed reconciliation also projects to zero resets; assert the commit.
        #expect(await classifier.applyRoutinePlaceChangeCoreForTesting(placeID: place.id)
                == .committed(resetCount: 0))
        let reloaded = try #require(try refetch(overridden.id, container))
        #expect(reloaded.category == .destination)
    }

    /// The explicit non-copy from the home path: this field is a function of
    /// HOMES only, so a copy-paste of `applyHomeChangeCore` would fail here.
    @Test("distanceFromHomeKm is never rewritten by a routine-place change")
    func distanceFromHomeIsNotTouched() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let place = makePlace(in: ctx, coord: gym, radiusMeters: 2000)
        let stay = makeStay(in: ctx, startDay: 1, category: .destination, coord: nearGym)
        try ctx.save()

        // A failed reconciliation writes nothing, so the distance check alone
        // would pass; assert the committed reset this fixture produces.
        #expect(await classifier.applyRoutinePlaceChangeCoreForTesting(placeID: place.id)
                == .committed(resetCount: 1))

        let reloaded = try #require(try refetch(stay.id, container))
        #expect(reloaded.distanceFromHomeKm == 4)
    }

    @Test("a second run is a no-op")
    func reconciliationIsIdempotent() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let place = makePlace(in: ctx, coord: gym, radiusMeters: 2000)
        makeStay(in: ctx, startDay: 1, category: .destination, coord: nearGym)
        try ctx.save()

        let first = await classifier.applyRoutinePlaceChangeCoreForTesting(placeID: place.id)
        let second = await classifier.applyRoutinePlaceChangeCoreForTesting(placeID: place.id)

        #expect(first == .committed(resetCount: 1))
        #expect(second == .committed(resetCount: 0))
    }

    @Test("routine-place save failure rolls back and schedules no reconciliation")
    func routinePlaceSaveFailureRollsBack() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let place = makePlace(in: ctx, coord: gym, radiusMeters: 500)
        let placeID = place.id
        try ctx.save()

        let payload = RoutinePlaceSavePayload(
            target: .edit(placeID),
            label: "Expanded Gym",
            latitude: gym.lat,
            longitude: gym.lon,
            radiusMeters: 2_000,
            now: date(day: 20))
        let result = RoutinePlaceSaveWorker.apply(
            payload,
            context: ctx,
            save: { _ in throw CocoaError(.fileWriteUnknown) })

        #expect(result.failed)
        #expect(result.reconcileID == nil)
        let fresh = ModelContext(container)
        let saved = try #require(try fresh.fetch(
            FetchDescriptor<RoutinePlace>(
                predicate: #Predicate { $0.id == placeID })
        ).first)
        #expect(saved.label == "Gym")
        #expect(saved.radiusMeters == 500)
    }

    @Test("routine-place save preserves unrelated pending edits before a failing save")
    func routinePlaceSavePreservesPendingEdits() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let place = makePlace(in: ctx, coord: gym, radiusMeters: 500)
        let placeID = place.id
        try ctx.save()
        place.label = "Pending edit"

        var saves = 0
        let payload = RoutinePlaceSavePayload(
            target: .add,
            label: "Library",
            latitude: nearGym.lat,
            longitude: nearGym.lon,
            radiusMeters: 300,
            now: date(day: 20))
        let result = RoutinePlaceSaveWorker.apply(
            payload,
            context: ctx,
            save: { context in
                saves += 1
                guard saves == 1 else { throw CocoaError(.fileWriteUnknown) }
                try context.save()
            })

        #expect(result.failed)
        #expect(result.reconcileID == nil)
        #expect(!ctx.hasChanges)
        let rows = try ModelContext(container).fetch(FetchDescriptor<RoutinePlace>())
        #expect(rows.count == 1)
        let saved = try #require(rows.first)
        #expect(saved.id == placeID)
        #expect(saved.label == "Pending edit")
    }

    @Test("routine-place edit of a missing row is a no-change success")
    func routinePlaceEditMissingRowIsNoChange() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let payload = RoutinePlaceSavePayload(
            target: .edit(UUID()),
            label: "Gym",
            latitude: gym.lat,
            longitude: gym.lon,
            radiusMeters: 500,
            now: date(day: 20))

        let result = RoutinePlaceSaveWorker.apply(payload, context: ctx)

        #expect(!result.failed)
        #expect(result.reconcileID == nil)
        #expect(try ctx.fetchCount(FetchDescriptor<RoutinePlace>()) == 0)
    }

    @Test("routine deactivation fails closed when its rows cannot be read")
    func routineDeactivationReadFailureRollsBack() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let place = makePlace(in: ctx, coord: gym, radiusMeters: 500)
        let placeID = place.id
        try ctx.save()
        place.label = "Pending edit"

        SettingsView.failRoutineFetchForTesting = true
        defer { SettingsView.failRoutineFetchForTesting = false }
        #expect(!SettingsView.deactivateRoutines(ids: [placeID], context: ctx))

        // The unrelated pending edit is committed, not discarded by the rollback.
        #expect(!ctx.hasChanges)
        #expect(place.label == "Pending edit")
        #expect(place.isActive)
        #expect(place.endedAt == nil)
        let fresh = ModelContext(container)
        let rows = try fresh.fetch(FetchDescriptor<RoutinePlace>())
        #expect(rows.count == 1)
        let saved = try #require(rows.first)
        #expect(saved.id == placeID)
        #expect(saved.label == "Pending edit")
        #expect(saved.isActive)
        #expect(saved.endedAt == nil)
    }

    @Test("routine deactivation succeeds when a successful read finds no matching rows")
    func routineDeactivationMissingRowIsNoOp() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let place = makePlace(in: ctx, coord: gym, radiusMeters: 500)
        try ctx.save()

        #expect(SettingsView.deactivateRoutines(ids: [UUID()], context: ctx))

        #expect(place.isActive)
        #expect(place.endedAt == nil)
        #expect(try ctx.fetchCount(FetchDescriptor<RoutinePlace>()) == 1)
        #expect(!ctx.hasChanges)
    }
}
