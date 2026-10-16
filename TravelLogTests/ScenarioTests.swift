//
//  ScenarioTests.swift
//  TravelLogTests
//
//  End-to-end user journeys. Each test
//  checks several production behaviors in one session:
//  correction → heal → undo → restore, backup → restore; and asserts what
//  the user would see at each surface afterward.
//
//  Same square-urban-centre harness as CorrectionChannelTests /
//  HomeAreaHealingTests.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Scenarios")
struct ScenarioTests {

    private static let day: TimeInterval = 24 * 60 * 60
    private static let home = (lat: 38.0, lon: 23.8)
    private static let village = (lat: 38.0, lon: 23.99)
    private static let faraway = (lat: 38.9, lon: 24.55)

    private func date(day offset: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: offset * Self.day)
    }

    private static func squareShape() -> HomeShape {
        HomeShape.urbanCentre(
            id: 1, name: "TestCity", areaKm2: 100,
            rings: [[[23.75, 37.95, 23.85, 37.95, 23.85, 38.05, 23.75, 38.05]]],
            centreLatitude: home.lat, centreLongitude: home.lon)
    }

    @discardableResult
    private func makeHome(in ctx: ModelContext) -> Home {
        let home = Home(label: "Home", latitude: Self.home.lat,
                        longitude: Self.home.lon, radiusKm: 25,
                        startedAt: date(day: -100))
        ctx.insert(home)
        return home
    }

    @discardableResult
    private func makeTrip(
        in ctx: ModelContext, startDay: Double,
        latitude: Double, longitude: Double, hex: String,
        distanceKm: Double = 17, name: String? = nil
    ) -> Trip {
        let trip = Trip(startDate: date(day: startDay))
        trip.endDate = date(day: startDay + 0.5)
        trip.isComplete = true
        trip.customName = name
        ctx.insert(trip)
        let start = date(day: startDay)
        let stay = Stay(
            startTime: start, endTime: start.addingTimeInterval(4 * 3600),
            centroidLatitude: latitude, centroidLongitude: longitude,
            h3IndexRes6: hex, pingCount: 2,
            distanceFromHomeKm: distanceKm, pingIDs: [])
        stay.category = .destination
        ctx.insert(stay)
        stay.trip = trip
        return trip
    }

    // MARK: - Scenario 1: a spot becomes home; dissolve, park, restore

    @Test("""
    work-spot lifecycle: membership claims a spot → the trip there dissolves \
    into the review queue and the residue stops being reviewable → manual \
    restore brings the trip back permanently
    """)
    func workSpotLifecycle() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let home = makeHome(in: ctx)
        // History at the village: one completed trip the pipeline minted…
        let tripID = makeTrip(in: ctx, startDay: 0, latitude: Self.village.lat,
                              longitude: Self.village.lon, hex: "V").id
        // …and a gate-suppressed errand (tripless destination residue).
        let residue = Stay(
            startTime: date(day: 5), endTime: date(day: 5).addingTimeInterval(2 * 3600),
            centroidLatitude: Self.village.lat, centroidLongitude: Self.village.lon,
            h3IndexRes6: "R", pingCount: 2, distanceFromHomeKm: 17, pingIDs: [])
        residue.category = .destination
        ctx.insert(residue)
        // The village joins the home area (a taught include; the same
        // membership a learned orbit disc would produce).
        ctx.insert(HomeAreaOverride(
            kind: .include, centerLatitude: Self.village.lat,
            centerLongitude: Self.village.lon, radiusKm: 1, homeID: home.id))
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())

        // Healing: the trip dissolves (parked, not destroyed), the residue
        // converts; the village is ordinary life now.
        let healed = await classifier.healHomeAreaCorrections(pinnedTripIDs: [])
        #expect(healed.moved == 2)
        #expect(try ctx.fetch(FetchDescriptor<Trip>()).isEmpty,
                "the trips list no longer shows the work-spot trip")
        #expect(await classifier.suppressedGroups().isEmpty,
                "the Near-Home review list no longer offers the claimed residue")
        let parked = await classifier.drainParkedDissolvedTrips()
        #expect(parked.map(\.id) == [tripID],
                "the Removed Trips list shows exactly the dissolved trip")

        // The user disagrees; Restore in the Removed Trips list.
        let record = try #require(parked.first)
        #expect(await classifier.restoreDissolvedTrip(record, markStaysSacred: true) == .restored)
        let restored = try #require(try ctx.fetch(FetchDescriptor<Trip>()).first)
        #expect(restored.id == tripID, "same trip, same favorites/photo keys")

        // The restore is permanent: the next heal (same membership) leaves it.
        #expect((await classifier.healHomeAreaCorrections(
            pinnedTripIDs: [])).moved == 0)
        #expect(try ctx.fetch(FetchDescriptor<Trip>()).count == 1)
    }

    // MARK: - Scenario 2: demote, sibling dissolves, undo, rescue the sibling

    @Test("""
    mistaken demote: "This Wasn't a Trip" dissolves the twin trip too → undo \
    brings back the demoted trip → the twin comes back from the review queue \
    with its identity intact
    """)
    func mistakenDemoteFullRecovery() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(in: ctx)
        let demotedID = makeTrip(in: ctx, startDay: 0, latitude: Self.village.lat,
                                 longitude: Self.village.lon, hex: "V",
                                 name: nil).id
        let twinID = makeTrip(in: ctx, startDay: 10, latitude: Self.village.lat,
                              longitude: Self.village.lon, hex: "V2").id
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())

        // Trip demotion parks the first trip's record. The
        // soft-delete contract also covers home-area healing.
        #expect(await classifier.demoteSeededTrip(demotedID).isDemoted)
        // …and the healing pass dissolves the twin (one correction heals the
        // class), parking it too.
        #expect((await classifier.healHomeAreaCorrections(
            pinnedTripIDs: [])).moved >= 1)
        let parked = await classifier.drainParkedDissolvedTrips()
        #expect(Set(parked.map(\.id)) == [demotedID, twinID])
        #expect(try ctx.fetch(FetchDescriptor<Trip>()).isEmpty)

        // The user realizes the mistake; undo.
        #expect(await classifier.undoLastDemotion() == .undone)
        let afterUndo = try ctx.fetch(FetchDescriptor<Trip>())
        #expect(afterUndo.map(\.id) == [demotedID],
                "undo restores the demoted trip itself")
        #expect(try ctx.fetch(FetchDescriptor<HomeAreaOverride>()).isEmpty,
                "the teaching is withdrawn with the undo")

        // The twin is still gone from the list; but not from the queue.
        let twinRecord = try #require(parked.first { $0.id == twinID })
        #expect(await classifier.restoreDissolvedTrip(twinRecord, markStaysSacred: true) == .restored)

        let finalTrips = try ctx.fetch(FetchDescriptor<Trip>())
        #expect(Set(finalTrips.map(\.id)) == [demotedID, twinID],
                "both trips back under their original identities")
        for stay in try ctx.fetch(FetchDescriptor<Stay>()) {
            #expect(stay.category == .destination)
            #expect(stay.trip != nil)
        }
    }

    // MARK: - Scenario 2b: the ONGOING trip survives demote + undo

    @Test("""
    demoting the trip you are currently ON and undoing brings it back \
    ONGOING — not frozen as a dateless completed trip that splits the journey
    """)
    func ongoingDemoteUndoStaysOngoing() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(in: ctx)
        // The user is mid-errand at the village: an ongoing trip.
        let trip = Trip(startDate: date(day: 0))
        trip.isComplete = false
        trip.endDate = nil
        ctx.insert(trip)
        let stay = Stay(
            startTime: date(day: 0), endTime: date(day: 0).addingTimeInterval(2 * 3600),
            centroidLatitude: Self.village.lat, centroidLongitude: Self.village.lon,
            h3IndexRes6: "V", pingCount: 2, distanceFromHomeKm: 17, pingIDs: [])
        stay.category = .destination
        ctx.insert(stay)
        stay.trip = trip
        let tripID = trip.id
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())

        // Mis-tap "This Wasn't a Trip" on the Currently Traveling row, then
        // Undo in the alert; the natural 5-second sequence.
        #expect(await classifier.demoteSeededTrip(tripID).isDemoted)
        _ = await classifier.drainParkedDissolvedTrips()
        #expect(await classifier.undoLastDemotion() == .undone)

        let restored = try #require(try ctx.fetch(FetchDescriptor<Trip>()).first)
        #expect(restored.id == tripID)
        #expect(!restored.isComplete,
                "still ongoing — a complete trip with nil endDate froze out of every ongoing mechanism")
        #expect(restored.endDate == nil)
        let restoredStay = try #require(try ctx.fetch(FetchDescriptor<Stay>()).first)
        #expect(restoredStay.trip?.id == tripID)
        #expect(restoredStay.category == .destination)
    }

    // MARK: - Scenario 3: backup → restore keeps the home area (v6)

    @Test("""
    backup/restore: a v6 export restored into a fresh store keeps trips, the \
    declared home, the taught overrides, and Arm-B sacred stays — and heals \
    to quiescence (nothing dissolves, nothing converts)
    """)
    func backupRestoreKeepsHomeArea() async throws {
        // Original store: home, taught include at the village, the sacred
        // home stay that teaching settled, and a genuine faraway trip.
        let source = try TestSupport.makeInMemoryContainer()
        let srcCtx = ModelContext(source)
        let homeRow = makeHome(in: srcCtx)
        let tripID = makeTrip(in: srcCtx, startDay: 0, latitude: Self.faraway.lat,
                              longitude: Self.faraway.lon, hex: "F",
                              distanceKm: 120, name: "Island Hop").id
        let overrideID = UUID()
        let taughtInclude = HomeAreaOverride(
            kind: .include, centerLatitude: Self.village.lat,
            centerLongitude: Self.village.lon, radiusKm: 1,
            homeID: homeRow.id, sourceTripName: "Village Weekend")
        taughtInclude.id = overrideID
        srcCtx.insert(taughtInclude)
        let sacred = Stay(
            startTime: date(day: 3), endTime: date(day: 3).addingTimeInterval(3 * 3600),
            centroidLatitude: Self.village.lat, centroidLongitude: Self.village.lon,
            h3IndexRes6: "S", pingCount: 2, distanceFromHomeKm: 17, pingIDs: [])
        sacred.category = .home
        sacred.userOverridden = true
        srcCtx.insert(sacred)
        try srcCtx.save()

        // Export exactly as SettingsModel.exportData assembles it.
        let trips = try srcCtx.fetch(FetchDescriptor<Trip>())
        let allStays = try srcCtx.fetch(FetchDescriptor<Stay>())
        let homes = try srcCtx.fetch(FetchDescriptor<Home>())
        let overrides = try srcCtx.fetch(FetchDescriptor<HomeAreaOverride>())
        let data = try #require(TripDataExporter.buildExportData(
            snapshots: TripDataExporter.makeSnapshots(from: trips),
            unassignedStays: TripDataExporter.makeUnassignedSnapshots(from: allStays),
            homes: TripDataExporter.makeHomeSnapshots(from: homes),
            homeStays: TripDataExporter.makeHomeStaySnapshots(from: allStays),
            homeAreaOverrides: TripDataExporter.makeOverrideSnapshots(from: overrides),
            appVersion: "test"))

        // Restore into a fresh store (new phone, blank install).
        let target = try TestSupport.makeInMemoryContainer()
        let importer = TripDataImporter(modelContainer: target)
        let payload = try TripDataImporter.parse(data)
        let outcome = await importer.importTrips(from: payload)
        #expect(outcome.insertedTrips == 1)
        #expect(outcome.insertedHomes == 1)
        #expect(outcome.insertedOverrides == 1)

        let ctx = ModelContext(target)
        let restoredTrip = try #require(try ctx.fetch(FetchDescriptor<Trip>()).first)
        #expect(restoredTrip.id == tripID)
        #expect(restoredTrip.customName == "Island Hop")
        let restoredHome = try #require(try ctx.fetch(FetchDescriptor<Home>()).first)
        #expect(restoredHome.id == homeRow.id)
        let restoredOverride = try #require(try ctx.fetch(
            FetchDescriptor<HomeAreaOverride>()).first)
        #expect(restoredOverride.id == overrideID)
        #expect(restoredOverride.homeID == homeRow.id)
        let restoredSacred = try #require(try ctx.fetch(FetchDescriptor<Stay>())
            .first { $0.h3IndexRes6 == "S" })
        #expect(restoredSacred.category == .home)
        #expect(restoredSacred.userOverridden,
                "the Arm-B teaching's consequence survived the restore")

        // The restored store is quiescent: healing finds nothing to dissolve
        // or convert; pre-v6, the missing overrides/home stays meant the
        // home area shrank and history re-judged wrongly.
        let classifier = TripClassifier(modelContainer: target)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        #expect((await classifier.healHomeAreaCorrections(
            pinnedTripIDs: [])).moved == 0)
        #expect(try ctx.fetch(FetchDescriptor<Trip>()).count == 1)
    }
}
