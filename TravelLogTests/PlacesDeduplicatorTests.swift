//
//  PlacesDeduplicatorTests.swift
//  TravelLogTests
//
//  Covers the proximity-based collapse of duplicate active Home / RoutinePlace
//  rows from two-device onboarding (the user-reported bug): close-enough rows
//  merge to a deterministic survivor; far-enough rows are both kept; ended /
//  inactive history is never touched; the pass is idempotent (no converge-to-
//  zero on a re-run while a loser is still visible mid-sync).
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
@Suite(.serialized)
struct PlacesDeduplicatorTests {

    /// The alias log is device-local state; keep it out of `.standard`.
    private static let aliasSuite = "PlacesDeduplicatorTests.aliases"
    private let aliasDefaults: UserDefaults

    init() {
        UserDefaults.standard.removePersistentDomain(forName: Self.aliasSuite)
        aliasDefaults = UserDefaults(suiteName: Self.aliasSuite)!
    }

    /// Fresh current-schema store per test, including home overrides.
    private func makeContainer() throws -> ModelContainer {
        TripTitleStore.invalidateHomePlaceIndex()
        let schema = Schema(versionedSchema: CurrentTravelLogSchema.self)
        let config = ModelConfiguration(url: TestSupport.temporaryStoreURL(), cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    // Athens center; ~0.001° ≈ 90 to 110 m, used to place "same place, jittered".
    private let athens = (lat: 37.9838, lon: 23.7275)

    /// Survivor selection keys on the immutable `id`, so tests pin ids
    /// explicitly (a random UUID would make "which row survives" flaky).
    static let lowID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let highID = UUID(uuidString: "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF")!

    @discardableResult
    private func insertHome(_ ctx: ModelContext, lat: Double, lon: Double,
                            label: String = "Home", startedAt: Date,
                            endedAt: Date? = nil, id: UUID? = nil) -> Home {
        let h = Home(label: label, latitude: lat, longitude: lon, startedAt: startedAt)
        h.endedAt = endedAt
        if let id { h.id = id }
        ctx.insert(h)
        return h
    }

    @discardableResult
    private func insertRoutine(_ ctx: ModelContext, lat: Double, lon: Double,
                              label: String = "University", startedAt: Date,
                              isActive: Bool = true, endedAt: Date? = nil,
                              id: UUID? = nil) -> RoutinePlace {
        let p = RoutinePlace(label: label, latitude: lat, longitude: lon, startedAt: startedAt)
        p.isActive = isActive
        p.endedAt = endedAt
        if let id { p.id = id }
        ctx.insert(p)
        return p
    }

    private func activeHomes(_ container: ModelContainer) throws -> [Home] {
        let ctx = ModelContext(container)
        return try ctx.fetch(FetchDescriptor<Home>(predicate: #Predicate { $0.endedAt == nil }))
    }

    private func allHomes(_ container: ModelContainer) throws -> [Home] {
        try ModelContext(container).fetch(FetchDescriptor<Home>())
    }

    private func activeRoutines(_ container: ModelContainer) throws -> [RoutinePlace] {
        let ctx = ModelContext(container)
        return try ctx.fetch(FetchDescriptor<RoutinePlace>(
            predicate: #Predicate { $0.isActive == true && $0.endedAt == nil }))
    }

    // MARK: - Pure proximity grouping

    @Test("proximityGroups groups near points and excludes far ones")
    func proximityGroupsBasic() {
        // Two points ~150 m apart, one ~3 km away.
        let near = (lat: athens.lat + 0.001, lon: athens.lon + 0.0005)
        let far = (lat: athens.lat + 0.03, lon: athens.lon)
        let groups = PlacesDeduplicator.proximityGroups(
            [athens, near, far], thresholdMeters: 1000)
        #expect(groups.count == 1)
        #expect(groups[0].sorted() == [0, 1])
    }

    @Test("proximityGroups returns nothing when all points are far apart")
    func proximityGroupsAllFar() {
        let groups = PlacesDeduplicator.proximityGroups(
            [athens, (lat: 39.66, lon: 20.85), (lat: 35.34, lon: 25.13)],
            thresholdMeters: 1000)
        #expect(groups.isEmpty)
    }

    // MARK: - Home dedup

    @Test("A failed override read aborts home deduplication and rolls back donor changes")
    func overrideReadFailurePreservesHomesAndOverrides() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let originalStart = Date(timeIntervalSinceReferenceDate: -16_933_400)
        insertHome(context, lat: athens.lat, lon: athens.lon,
                   label: "", startedAt: originalStart, id: Self.lowID)
        insertHome(context, lat: athens.lat + 0.001, lon: athens.lon,
                   label: "Donor", startedAt: originalStart.addingTimeInterval(-600), id: Self.highID)
        context.insert(HomeAreaOverride(kind: .include,
            centerLatitude: athens.lat, centerLongitude: athens.lon,
            radiusKm: 2, homeID: Self.highID))
        try context.save()

        PlacesDeduplicator.failOverrideFetchForTestingContainer = container
        defer { PlacesDeduplicator.failOverrideFetchForTestingContainer = nil }
        var threw = false
        do {
            _ = try PlacesDeduplicator.deduplicateHomes(in: context)
        } catch {
            threw = true
            // The helper leaves transaction ownership with its caller.
            context.rollback()
        }
        #expect(threw)
        #expect(!context.hasChanges)
        #expect(try context.fetchCount(FetchDescriptor<Home>()) == 2)
        #expect(try context.fetch(FetchDescriptor<HomeAreaOverride>()).map(\.homeID) == [Self.highID])

        // Also exercise the production caller's rollback catch.
        await PlacesDeduplicator.deduplicateAll(modelContainer: container, defaults: aliasDefaults)
        let verification = ModelContext(container)
        let homes = try verification.fetch(FetchDescriptor<Home>())
        #expect(homes.count == 2)
        let survivor = try #require(homes.first { $0.id == Self.lowID })
        #expect(survivor.label.isEmpty)
        #expect(survivor.startedAt == originalStart)
        #expect(try verification.fetch(FetchDescriptor<HomeAreaOverride>()).map(\.homeID) == [Self.highID])
    }

    @Test("two active homes within 1 km collapse to the smallest-id survivor")
    func homesWithinThresholdCollapse() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let t0 = Date(timeIntervalSinceReferenceDate: -16_933_400)
        let survivorID = insertHome(ctx, lat: athens.lat, lon: athens.lon,
                                    label: "Athens", startedAt: t0, id: Self.lowID).id
        // ~150 m away, created later (device 2).
        insertHome(ctx, lat: athens.lat + 0.001, lon: athens.lon,
                   label: "", startedAt: t0.addingTimeInterval(60), id: Self.highID)
        try ctx.save()

        await PlacesDeduplicator.deduplicateAll(modelContainer: container, defaults: aliasDefaults)

        let remaining = try activeHomes(container)
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == survivorID)  // smallest immutable id wins
        // Empty survivor label is NOT overwritten by an empty loser; survivor
        // kept its own "Athens".
        #expect(remaining.first?.label == "Athens")
    }

    @Test("survivor keys on the immutable id and absorbs the earliest startedAt")
    func homeSurvivorKeyImmuneToStartedAtMutation() async throws {
        // `applyHomeChangeCore` BACKDATES Home.startedAt on an ordinary
        // Settings coverage edit, so two devices' mid-propagation views can
        // disagree on startedAt; a startedAt-keyed survivor pick then
        // delete-wars to zero active homes. The id key is
        // immutable, so both devices always agree; the survivor absorbs the
        // group's earliest startedAt so the oldest coverage window survives
        // the collapse.
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let t0 = Date(timeIntervalSinceReferenceDate: -16_933_400)
        // The EARLIER-started row carries the LARGER id: under the old
        // (startedAt, id) rule it would survive; under the id rule it loses
        // but donates its startedAt.
        insertHome(ctx, lat: athens.lat, lon: athens.lon,
                   label: "Early", startedAt: t0, id: Self.highID)
        insertHome(ctx, lat: athens.lat + 0.001, lon: athens.lon,
                   label: "Late", startedAt: t0.addingTimeInterval(600), id: Self.lowID)
        try ctx.save()

        await PlacesDeduplicator.deduplicateAll(modelContainer: container, defaults: aliasDefaults)

        let remaining = try activeHomes(container)
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == Self.lowID)
        #expect(remaining.first?.startedAt == t0)  // earliest window absorbed
        #expect(remaining.first?.label == "Late")  // non-empty label kept
    }

    @Test("two active homes more than 1 km apart are both kept")
    func homesBeyondThresholdKept() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let t0 = Date(timeIntervalSinceReferenceDate: -16_933_400)
        insertHome(ctx, lat: athens.lat, lon: athens.lon, startedAt: t0)
        // ~3.3 km north; a genuinely different home.
        insertHome(ctx, lat: athens.lat + 0.03, lon: athens.lon, startedAt: t0.addingTimeInterval(60))
        try ctx.save()

        await PlacesDeduplicator.deduplicateAll(modelContainer: container, defaults: aliasDefaults)

        #expect(try activeHomes(container).count == 2)
    }

    @Test("survivor backfills nil geocode fields from the deleted duplicate")
    func homeSurvivorInheritsGeocode() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let t0 = Date(timeIntervalSinceReferenceDate: -16_933_400)
        _ = insertHome(ctx, lat: athens.lat, lon: athens.lon, label: "", startedAt: t0, id: Self.lowID)
        // survivor has nil locality/country; the later duplicate carries them.
        let dup = insertHome(ctx, lat: athens.lat + 0.001, lon: athens.lon,
                             label: "Gérakas", startedAt: t0.addingTimeInterval(60), id: Self.highID)
        dup.locality = "Gérakas"; dup.country = "Greece"; dup.isoCountryCode = "GR"
        try ctx.save()

        await PlacesDeduplicator.deduplicateAll(modelContainer: container, defaults: aliasDefaults)

        let remaining = try activeHomes(container)
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == Self.lowID)
        #expect(remaining.first?.locality == "Gérakas")
        #expect(remaining.first?.isoCountryCode == "GR")
        #expect(remaining.first?.label == "Gérakas")  // empty survivor label filled
    }

    @Test("home dedup keeps titles when the collapsed twin has the same prompt content")
    func homeDedupKeepsTitlesForSameContentTwin() async throws {
        let (container, tripID) = try makeTitledHomeTwins(
            survivorLocality: "Athens", loserLocality: "Athens")

        await PlacesDeduplicator.deduplicateAll(modelContainer: container, defaults: aliasDefaults)

        let fresh = ModelContext(container)
        #expect(try fresh.fetchCount(FetchDescriptor<Home>(
            predicate: #Predicate { $0.endedAt == nil })) == 1)
        let savedTrip = try #require(try fresh.fetch(FetchDescriptor<Trip>(
            predicate: #Predicate { $0.id == tripID })).first)
        #expect(savedTrip.aiGeneratedTitle == "Existing Title")
        #expect((savedTrip.localizedTitles ?? []).count == 1)
    }

    @Test("home dedup invalidates titles when the collapsed twin carried a different locality")
    func homeDedupInvalidatesGeneratedTitles() async throws {
        let (container, tripID) = try makeTitledHomeTwins(
            survivorLocality: "Gérakas", loserLocality: "Palaió Fáliro")

        await PlacesDeduplicator.deduplicateAll(modelContainer: container, defaults: aliasDefaults)

        let fresh = ModelContext(container)
        #expect(try fresh.fetchCount(FetchDescriptor<Home>(
            predicate: #Predicate { $0.endedAt == nil })) == 1)
        let savedTrip = try #require(try fresh.fetch(FetchDescriptor<Trip>(
            predicate: #Predicate { $0.id == tripID })).first)
        #expect(savedTrip.aiGeneratedTitle == nil)
        #expect((savedTrip.localizedTitles ?? []).isEmpty)
    }

    private func makeTitledHomeTwins(
        survivorLocality: String,
        loserLocality: String
    ) throws -> (ModelContainer, UUID) {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let t0 = Date(timeIntervalSinceReferenceDate: -16_933_400)
        let first = insertHome(
            ctx, lat: athens.lat, lon: athens.lon,
            label: "Athens", startedAt: t0, id: Self.lowID)
        first.locality = survivorLocality
        first.country = "Greece"
        first.isoCountryCode = "GR"
        let duplicate = insertHome(
            ctx, lat: athens.lat + 0.001, lon: athens.lon,
            label: "Second Device", startedAt: t0,
            id: Self.highID)
        duplicate.locality = loserLocality
        duplicate.country = "Greece"
        duplicate.isoCountryCode = "GR"
        let trip = Trip(startDate: t0)
        trip.aiGeneratedTitle = "Existing Title"
        ctx.insert(trip)
        ctx.insert(TripTitleVariant(
            languageTag: "de",
            title: "Bestehender Titel",
            sourceTitle: "Existing Title",
            trip: trip))
        let tripID = trip.id
        try ctx.save()
        return (container, tripID)
    }

    @Test("an ended home at the same coordinate is never touched (history preserved)")
    func endedHomePreserved() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let t0 = Date(timeIntervalSinceReferenceDate: -16_933_400)
        // One active + one ENDED home at the same spot (a real past home).
        insertHome(ctx, lat: athens.lat, lon: athens.lon, startedAt: t0)
        insertHome(ctx, lat: athens.lat, lon: athens.lon, startedAt: t0.addingTimeInterval(-10_000),
                   endedAt: t0.addingTimeInterval(-5_000))
        try ctx.save()

        await PlacesDeduplicator.deduplicateAll(modelContainer: container, defaults: aliasDefaults)

        #expect(try activeHomes(container).count == 1)   // active untouched
        #expect(try allHomes(container).count == 2)      // ended row still there
    }

    @Test("dedup is idempotent; a second run is a no-op, never converges to zero")
    func homeDedupIdempotent() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let t0 = Date(timeIntervalSinceReferenceDate: -16_933_400)
        insertHome(ctx, lat: athens.lat, lon: athens.lon, startedAt: t0)
        insertHome(ctx, lat: athens.lat + 0.001, lon: athens.lon, startedAt: t0.addingTimeInterval(60))
        try ctx.save()

        await PlacesDeduplicator.deduplicateAll(modelContainer: container, defaults: aliasDefaults)
        await PlacesDeduplicator.deduplicateAll(modelContainer: container, defaults: aliasDefaults)

        #expect(try activeHomes(container).count == 1)
    }

    // MARK: - RoutinePlace dedup

    @Test("two active routine places within 250 m collapse; survivor is smallest-id")
    func routinesWithinThresholdCollapse() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let t0 = Date(timeIntervalSinceReferenceDate: -16_933_400)
        let survivorID = insertRoutine(ctx, lat: athens.lat, lon: athens.lon, startedAt: t0,
                                       id: Self.lowID).id
        // ~110 m away.
        insertRoutine(ctx, lat: athens.lat + 0.001, lon: athens.lon,
                      startedAt: t0.addingTimeInterval(60), id: Self.highID)
        try ctx.save()

        await PlacesDeduplicator.deduplicateAll(modelContainer: container, defaults: aliasDefaults)

        let remaining = try activeRoutines(container)
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == survivorID)
    }

    @Test("two routine places ~400 m apart are both kept (below home threshold, above routine)")
    func routinesBeyondTighterThresholdKept() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let t0 = Date(timeIntervalSinceReferenceDate: -16_933_400)
        insertRoutine(ctx, lat: athens.lat, lon: athens.lon, startedAt: t0)
        // ~440 m east; distinct routine places (gym vs office) are kept.
        insertRoutine(ctx, lat: athens.lat, lon: athens.lon + 0.005, startedAt: t0.addingTimeInterval(60))
        try ctx.save()

        await PlacesDeduplicator.deduplicateAll(modelContainer: container, defaults: aliasDefaults)

        #expect(try activeRoutines(container).count == 2)
    }

    @Test("inactive routine place at the same coordinate is never touched")
    func inactiveRoutinePreserved() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let t0 = Date(timeIntervalSinceReferenceDate: -16_933_400)
        insertRoutine(ctx, lat: athens.lat, lon: athens.lon, startedAt: t0)
        insertRoutine(ctx, lat: athens.lat, lon: athens.lon, startedAt: t0.addingTimeInterval(-10_000),
                      isActive: false, endedAt: t0.addingTimeInterval(-5_000))
        try ctx.save()

        await PlacesDeduplicator.deduplicateAll(modelContainer: container, defaults: aliasDefaults)

        #expect(try activeRoutines(container).count == 1)
        #expect(try ModelContext(container).fetch(FetchDescriptor<RoutinePlace>()).count == 2)
    }

    @Test("survivor keeps the WIDER radius from a deleted duplicate")
    func survivorKeepsWiderRadius() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let t0 = Date(timeIntervalSinceReferenceDate: -16_933_400)
        // The survivor (smallest id) has the default 25 km; the later
        // duplicate was widened to 40 km on the other device.
        let survivor = insertHome(ctx, lat: athens.lat, lon: athens.lon, startedAt: t0, id: Self.lowID)
        survivor.radiusKm = 25
        let dup = insertHome(ctx, lat: athens.lat + 0.001, lon: athens.lon,
                             startedAt: t0.addingTimeInterval(60), id: Self.highID)
        dup.radiusKm = 40
        try ctx.save()

        await PlacesDeduplicator.deduplicateAll(modelContainer: container, defaults: aliasDefaults)

        let remaining = try activeHomes(container)
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == Self.lowID)
        #expect(remaining.first?.radiusKm == 40)  // wider radius wins, no coverage loss
    }

    @Test("a single home of each kind is left alone")
    func singletonsUntouched() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let t0 = Date(timeIntervalSinceReferenceDate: -16_933_400)
        insertHome(ctx, lat: athens.lat, lon: athens.lon, startedAt: t0)
        insertRoutine(ctx, lat: athens.lat, lon: athens.lon, startedAt: t0)
        try ctx.save()

        await PlacesDeduplicator.deduplicateAll(modelContainer: container, defaults: aliasDefaults)

        #expect(try activeHomes(container).count == 1)
        #expect(try activeRoutines(container).count == 1)
    }
}
