//
//  P04RegressionTests.swift
//  TravelLogTests
//
//  Home authority, coverage and review: who may teach a home area, which
//  reads a destructive unit needs, and what a review must still hold when
//  its save runs. Fictional places and dates only.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite(IsolatedTitleDefaults())
struct P04RegressionTests {

    private static let day: TimeInterval = 24 * 60 * 60
    private static let home = (lat: 44.3, lon: 12.9)
    /// About 16 km east of the home pin, outside its square seed.
    private static let village = (lat: 44.3, lon: 13.1)

    private func date(day offset: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: (offset + 400) * Self.day)
    }

    private static func squareShape() -> HomeShape {
        TemporaryHomeFixture.squareShape(id: 1, around: home)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "P04RegressionTests-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    // MARK: - FU-4: healing debt survives a fingerprint that moves back

    /// What a staged healing run saw, mutated from the stages' closures.
    @MainActor
    private final class HealProbe {
        var readings: [String] = []
        var fingerprint = "F"
        var heals = 0
        var fails = false
    }

    private func stages(_ probe: HealProbe) -> HomeAreaHealing.Stages {
        HomeAreaHealing.Stages(
            rescue: {},
            fingerprint: { probe.readings.isEmpty ? probe.fingerprint : probe.readings.removeFirst() },
            heal: { _ in
                probe.heals += 1
                return .init(moved: 0, failed: probe.fails)
            },
            drainParked: { [] }, classify: { true }, generateTitles: {},
            coverage: { [] }, bumpChanges: {}, reloadWidgets: {})
    }

    @Test("a heal whose input moves back to the stamped value before its pass stamps stays owed: the next run heals and stamps")
    func healingDebtSurvivesAFingerprintThatMovesBack() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("F", forKey: HomeAreaHealing.fingerprintKey)
        // Twins arrive: the heal sees F#twins and defers their trip; the
        // finalizing pass removes the empty open twin, so the input reads F again.
        let probe = HealProbe()
        probe.readings = ["F#twins=a", "F"]
        #expect(await HomeAreaHealing.healIfNeeded(defaults: defaults, stages: stages(probe)))
        #expect(probe.heals == 1)
        #expect(defaults.string(forKey: HomeAreaHealing.fingerprintKey) == "F")
        #expect(defaults.bool(forKey: HomeAreaHealing.owedKey))

        // The stamp equals the input again, but the deferred heal is owed.
        #expect(await HomeAreaHealing.healIfNeeded(defaults: defaults, stages: stages(probe)))
        #expect(probe.heals == 2)
        #expect(defaults.string(forKey: HomeAreaHealing.fingerprintKey) == "F")
        #expect(!defaults.bool(forKey: HomeAreaHealing.owedKey))

        // Stamped and settled: an unchanged input skips.
        #expect(await HomeAreaHealing.healIfNeeded(defaults: defaults, stages: stages(probe)))
        #expect(probe.heals == 2)
    }

    @Test("a heal that fails stays owed even when the input then reads as the old stamp")
    func failedHealStaysOwed() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("F", forKey: HomeAreaHealing.fingerprintKey)
        let probe = HealProbe()
        probe.fingerprint = "F#twins=a"
        probe.fails = true
        #expect(!(await HomeAreaHealing.healIfNeeded(defaults: defaults, stages: stages(probe))))
        probe.fingerprint = "F"
        probe.fails = false
        #expect(await HomeAreaHealing.healIfNeeded(defaults: defaults, stages: stages(probe)))
        #expect(probe.heals == 2)
        #expect(!defaults.bool(forKey: HomeAreaHealing.owedKey))
    }

    // MARK: - OWN-002: import-only merged stays never teach a home area

    /// Three days of: live home overnight, five hours at the village, live
    /// home again. Each village stay is merged from two pings of `sources`.
    private func seedReturns(
        _ ctx: ModelContext, villageSources sources: [DataSource]
    ) -> (village: [Stay], pings: [LocationPing]) {
        var village: [Stay] = []
        var pings: [LocationPing] = []
        for offset in 0..<3 {
            let dayStart = 10 + Double(offset)
            for (start, hours) in [(dayStart, 8.0), (dayStart + 17.0 / 24, 6.5)] {
                let stay = Stay(
                    startTime: date(day: start), endTime: date(day: start).addingTimeInterval(hours * 3600),
                    centroidLatitude: Self.home.lat, centroidLongitude: Self.home.lon,
                    h3IndexRes6: "H", pingCount: 2, distanceFromHomeKm: 0, pingIDs: [])
                stay.category = .home
                ctx.insert(stay)
            }
            let start = date(day: dayStart + 10.0 / 24)
            let own = sources.map { source in
                LocationPing(timestamp: start, latitude: Self.village.lat, longitude: Self.village.lon,
                             horizontalAccuracy: 10, h3IndexRes6: "V", source: source)
            }
            own.forEach(ctx.insert)
            pings += own
            let stay = Stay(
                startTime: start, endTime: start.addingTimeInterval(5 * 3600),
                centroidLatitude: Self.village.lat, centroidLongitude: Self.village.lon,
                h3IndexRes6: "V", pingCount: own.count, distanceFromHomeKm: 16,
                pingIDs: own.map(\.id), source: .merged)
            stay.category = .destination
            ctx.insert(stay)
            village.append(stay)
        }
        return (village, pings)
    }

    private func orbitFixture(
        villageSources: [DataSource]
    ) async throws -> (container: ModelContainer, classifier: TripClassifier, home: UUID,
                       village: [Stay], pings: [LocationPing]) {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let home = Home(label: "Home", latitude: Self.home.lat, longitude: Self.home.lon,
                        radiusKm: 25, startedAt: date(day: 0))
        ctx.insert(home)
        let seeded = seedReturns(ctx, villageSources: villageSources)
        try ctx.save()
        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon, shape: Self.squareShape())
        return (container, classifier, home.id, seeded.village, seeded.pings)
    }

    @Test("merged stays built from imports alone (Timeline with GPX) teach no home area, and gaining a live fix of their own, with the stay rows unchanged, teaches it at the next prime")
    func importOnlyMergedStaysLearnNoOrbit() async throws {
        let fixture = try await orbitFixture(villageSources: [.timelineImport, .gpxImport])
        let before = await fixture.classifier.primedOrbitsForTesting()
        #expect((before[fixture.home.uuidString] ?? []).isEmpty)
        #expect(await fixture.classifier.learnedPlaces().isEmpty)
        #expect(await fixture.classifier.currentMembershipCovers(
            latitude: Self.village.lat, longitude: Self.village.lon) == false)

        // Only the ping rows change: the merged stays read the same.
        let ctx = ModelContext(fixture.container)
        let ids = Set(fixture.pings.map(\.id))
        for ping in try ctx.fetch(FetchDescriptor<LocationPing>()) where ids.contains(ping.id)
            && ping.sourceRaw == DataSource.timelineImport.rawValue {
            ping.sourceRaw = DataSource.foregroundStream.rawValue
        }
        try ctx.save()
        let after = await fixture.classifier.primedOrbitsForTesting()
        #expect(after[fixture.home.uuidString]?.count == 1)
    }

    @Test("a merged stay a native Visit backs stays live evidence for learning")
    func visitBackedMergedStaysStillLearn() async throws {
        let fixture = try await orbitFixture(villageSources: [.photoImport, .gpxImport])
        let ctx = ModelContext(fixture.container)
        for stay in fixture.village {
            ctx.insert(Visit(arrivalDate: stay.startTime, departureDate: stay.endTime,
                             latitude: Self.village.lat, longitude: Self.village.lon,
                             stayID: stay.id))
        }
        try ctx.save()
        let orbits = await fixture.classifier.primedOrbitsForTesting()
        #expect(orbits[fixture.home.uuidString]?.count == 1)
    }

    @Test("an unchanged store primes orbits without reading pings again, an unrelated fix reads none, and a live fix that syncs in after its merged stay is read alone and teaches the area")
    func mergedLiveSupportReadsOnlyWhatChanged() async throws {
        let fixture = try await orbitFixture(villageSources: [.timelineImport, .gpxImport])
        // Each village stay also names a live fix this device has not received yet.
        let ctx = ModelContext(fixture.container)
        var pending: [(id: UUID, at: Date)] = []
        for stay in try ctx.fetch(FetchDescriptor<Stay>()) where stay.source == .merged {
            let id = UUID()
            stay.appendPingID(id)
            pending.append((id, stay.startTime.addingTimeInterval(3600)))
        }
        try ctx.save()
        let classifier = fixture.classifier
        #expect((await classifier.primedOrbitsForTesting()[fixture.home.uuidString] ?? []).isEmpty)
        let queries = await classifier.mergedSupportPingQueryCountForTesting
        #expect(queries > 0)

        _ = await classifier.primedOrbitsForTesting()
        #expect(await classifier.mergedSupportPingQueryCountForTesting == queries)

        let unrelated = LocationPing(timestamp: date(day: 30), latitude: Self.home.lat, longitude: Self.home.lon,
                                     horizontalAccuracy: 10, h3IndexRes6: "H", source: .liveSLC)
        ctx.insert(unrelated)
        try ctx.save()
        #expect((await classifier.primedOrbitsForTesting()[fixture.home.uuidString] ?? []).isEmpty)
        #expect(await classifier.mergedSupportPingQueryCountForTesting == queries)

        for (id, at) in pending {
            let ping = LocationPing(timestamp: at, latitude: Self.village.lat, longitude: Self.village.lon,
                                    horizontalAccuracy: 10, h3IndexRes6: "V", source: .liveSLC)
            ping.id = id
            ctx.insert(ping)
        }
        try ctx.save()
        #expect(await classifier.primedOrbitsForTesting()[fixture.home.uuidString]?.count == 1)
        #expect(await classifier.mergedSupportPingQueryCountForTesting == queries + 1)
    }

    // MARK: - TEMP-002: a save commits only on the inputs its review read

    private func addPayload(
        reviewed: TemporaryHomeSaveWorker.ReviewedInputs?, keptTripIDs: [UUID] = []
    ) -> TemporaryHomeSavePayload {
        TemporaryHomeSavePayload(
            target: .add, label: "Semester", latitude: Self.village.lat, longitude: Self.village.lon,
            locality: nil, administrativeArea: nil, country: nil, isoCountryCode: nil,
            startedAt: date(day: 10), endedAt: date(day: 60), timeZoneIdentifier: "GMT",
            now: date(day: 70), keptTripIDs: keptTripIDs, reviewed: reviewed)
    }

    @Test("the review's revision counts a write the moment it is recorded, before the debounce, for every table the preview reads, photo rows and Homes included, and not for an unrelated one")
    func reviewRevisionCountsPendingWrites() {
        let tracker = StoreChangeTracker(forTesting: ())
        let tables = TemporaryHomeFormSheet.reviewedChanges
        #expect(tables.isSuperset(of: [.stay, .trip, .temporaryHome, .home, .homeAreaOverride,
                                       .routinePlace, .visit, .hiddenPhoto, .pinnedPhoto]))
        let start = tracker.revision(for: tables)
        tracker.bump(.hexVisit)
        #expect(tracker.revision(for: tables) == start)
        tracker.bump(.pinnedPhoto)
        // Still pending: the observed token has not moved, the revision has.
        #expect(tracker.hasPendingBump(.pinnedPhoto))
        #expect(tracker.token(for: tables) == 0)
        #expect(tracker.revision(for: tables) == start + 1)
        tracker.bump([.hiddenPhoto, .home])
        #expect(tracker.revision(for: tables) == start + 3)
    }

    @Test("a save whose review a queued photo-only write or a synced favourite overtook writes nothing, holds no trip and queues nothing; with its inputs unchanged it commits")
    func staleReviewWritesNothing() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = Trip(startDate: date(day: 20))
        ctx.insert(trip)
        try ctx.save()
        let tripID = trip.id
        let tracker = StoreChangeTracker(forTesting: ())
        let favourites: Set<UUID> = []
        let reviewed = TemporaryHomeSaveWorker.currentInputs(tracker: tracker, pinnedTripIDs: favourites)

        // A photo pin queued from Trip Detail lands before the save's turn.
        tracker.bump(.pinnedPhoto)
        let photoOnly = TemporaryHomeSaveWorker.applyIfStillReviewed(
            addPayload(reviewed: reviewed, keptTripIDs: [tripID]), context: ModelContext(container),
            tracker: tracker, pinnedTripIDs: favourites, pendingDefaults: defaults)
        #expect(photoOnly == .staleReview)

        // A favourite synced in since the review read.
        let fresh = TemporaryHomeSaveWorker.currentInputs(tracker: tracker, pinnedTripIDs: favourites)
        let favourited = TemporaryHomeSaveWorker.applyIfStillReviewed(
            addPayload(reviewed: fresh, keptTripIDs: [tripID]), context: ModelContext(container),
            tracker: tracker, pinnedTripIDs: [tripID], pendingDefaults: defaults)
        #expect(favourited == .staleReview)

        let check = ModelContext(container)
        #expect(try check.fetch(FetchDescriptor<TemporaryHome>()).isEmpty)
        #expect(try check.fetch(FetchDescriptor<Trip>()).allSatisfy { !$0.userEdited })
        #expect(CoverageReconciliationQueue.pending(defaults: defaults).isEmpty)

        let saved = TemporaryHomeSaveWorker.applyIfStillReviewed(
            addPayload(reviewed: fresh, keptTripIDs: [tripID]), context: ModelContext(container),
            tracker: tracker, pinnedTripIDs: favourites, pendingDefaults: defaults)
        #expect(!saved.failed && !saved.needsReview)
        #expect(try ModelContext(container).fetch(FetchDescriptor<TemporaryHome>()).count == 1)
        #expect(try ModelContext(container).fetch(FetchDescriptor<Trip>()).allSatisfy(\.userEdited))
        #expect(CoverageReconciliationQueue.pending(defaults: defaults).count == 1)
    }

    // MARK: - SET-001: a Settings edit writes every current same-id twin

    private func homePayload(
        _ id: UUID, at place: (lat: Double, lon: Double), radiusKm: Double = 25
    ) -> HomeSavePayload {
        HomeSavePayload(
            target: .edit(id), label: "Home", latitude: place.lat, longitude: place.lon,
            radiusKm: radiusKm, locality: nil, administrativeArea: nil, country: nil,
            isoCountryCode: nil, endingExistingHomes: false, shownActiveHomeIDs: [],
            now: date(day: 50))
    }

    /// Two physical rows of one Home id, as two devices restoring one backup leave them.
    private func homeTwins(_ ctx: ModelContext) throws -> UUID {
        let first = Home(label: "Home", latitude: Self.home.lat, longitude: Self.home.lon,
                         radiusKm: 25, startedAt: date(day: 0))
        let twin = Home(label: "Home", latitude: Self.home.lat, longitude: Self.home.lon,
                        radiusKm: 25, startedAt: date(day: 0))
        twin.id = first.id
        ctx.insert(first)
        ctx.insert(twin)
        try ctx.save()
        return first.id
    }

    @Test("moving a Home with a same-id twin past 1 km ends every twin and versions one successor; no old row stays current")
    func homeMoveEndsEveryTwin() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let id = try homeTwins(ModelContext(container))
        let result = HomeSaveWorker.apply(
            homePayload(id, at: (Self.home.lat + 0.1, Self.home.lon)),
            context: ModelContext(container), pendingDefaults: defaults)
        #expect(!result.failed)
        let homes = try ModelContext(container).fetch(FetchDescriptor<Home>())
        let old = homes.filter { $0.id == id }
        #expect(old.count == 2)
        #expect(old.allSatisfy { $0.endedAt == date(day: 50) })
        let current = homes.filter(\.isCurrent)
        #expect(current.count == 1)
        #expect(current.first?.id != id)
        #expect(current.first?.latitude == Self.home.lat + 0.1)
    }

    @Test("a small Home edit with a same-id twin updates every twin in place and reconciles once")
    func homeMinorEditUpdatesEveryTwin() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let id = try homeTwins(ModelContext(container))
        let result = HomeSaveWorker.apply(
            homePayload(id, at: (Self.home.lat, Self.home.lon), radiusKm: 5),
            context: ModelContext(container), pendingDefaults: defaults)
        #expect(result.reconcileHomeID == id)
        let homes = try ModelContext(container).fetch(FetchDescriptor<Home>())
        #expect(homes.count == 2)
        #expect(homes.allSatisfy { $0.id == id && $0.radiusKm == 5 && $0.isCurrent })
    }

    @Test("moving a routine place with a same-id twin past 500 m ends every twin; a small edit updates every twin")
    func routineEditWritesEveryTwin() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let first = RoutinePlace(label: "Gym", latitude: Self.village.lat, longitude: Self.village.lon,
                                 radiusMeters: 300, startedAt: date(day: 0))
        let twin = RoutinePlace(label: "Gym", latitude: Self.village.lat, longitude: Self.village.lon,
                                radiusMeters: 300, startedAt: date(day: 0))
        twin.id = first.id
        ctx.insert(first)
        ctx.insert(twin)
        try ctx.save()
        let id = first.id
        func payload(_ lat: Double, radius: Double) -> RoutinePlaceSavePayload {
            RoutinePlaceSavePayload(target: .edit(id), label: "Gym", latitude: lat,
                                    longitude: Self.village.lon, radiusMeters: radius,
                                    now: date(day: 50))
        }

        let minor = RoutinePlaceSaveWorker.apply(
            payload(Self.village.lat, radius: 100), context: ModelContext(container),
            pendingDefaults: defaults)
        #expect(minor.reconcileID == id)
        var rows = try ModelContext(container).fetch(FetchDescriptor<RoutinePlace>())
        #expect(rows.count == 2 && rows.allSatisfy { $0.radiusMeters == 100 && $0.isCurrent })

        _ = RoutinePlaceSaveWorker.apply(
            payload(Self.village.lat + 0.02, radius: 100), context: ModelContext(container),
            pendingDefaults: defaults)
        rows = try ModelContext(container).fetch(FetchDescriptor<RoutinePlace>())
        #expect(rows.filter { $0.id == id }.allSatisfy { $0.endedAt == date(day: 50) })
        #expect(rows.filter(\.isCurrent).count == 1)
        #expect(rows.filter(\.isCurrent).first?.id != id)
    }

    // MARK: - SET-004: a failed active-home read never skips Keep Both / Replace

    @Test("Add Home refuses to save when the active homes cannot be read, asks Keep Both or Replace when one is active, and saves directly only after a read that found none")
    func addHomePreflightFailsClosed() {
        #expect(HomeSaveDecision.addRoute(activeHomeCount: nil) == .refuse)
        #expect(HomeSaveDecision.addRoute(activeHomeCount: 1) == .askChoice)
        #expect(HomeSaveDecision.addRoute(activeHomeCount: 0) == .saveDirectly)
    }

    // MARK: - HOME-005: healing reads the corrections it applies

    @Test("healing fails before touching a trip when its corrections cannot be read, and heals once they can")
    func healingOverrideReadFailureFailsClosed() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let home = Home(label: "Home", latitude: Self.home.lat, longitude: Self.home.lon,
                        radiusKm: 25, startedAt: date(day: -100))
        ctx.insert(home)
        let trip = Trip(startDate: date(day: 0))
        trip.endDate = date(day: 0.5)
        trip.isComplete = true
        ctx.insert(trip)
        let stay = Stay(
            startTime: date(day: 0), endTime: date(day: 0).addingTimeInterval(4 * 3600),
            centroidLatitude: Self.village.lat, centroidLongitude: Self.village.lon,
            h3IndexRes6: "V", pingCount: 2, distanceFromHomeKm: 16, pingIDs: [])
        stay.category = .destination
        ctx.insert(stay)
        stay.trip = trip
        ctx.insert(HomeAreaOverride(
            kind: .include, centerLatitude: Self.village.lat, centerLongitude: Self.village.lon,
            radiusKm: 1, homeID: home.id))
        try ctx.save()
        let tripID = trip.id

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon, shape: Self.squareShape())
        // The Home read succeeds; the corrections read right after it fails.
        await classifier.failHomeAreaHealingFetchCallForTesting(2)
        let failed = await classifier.healHomeAreaCorrections(pinnedTripIDs: [])
        #expect(failed.failed && failed.moved == 0)
        #expect(try ModelContext(container).fetch(FetchDescriptor<Trip>()).map(\.id) == [tripID])

        let healed = await classifier.healHomeAreaCorrections(pinnedTripIDs: [])
        #expect(!healed.failed && healed.moved == 1)
        #expect(try ModelContext(container).fetch(FetchDescriptor<Trip>()).isEmpty)
    }

    // MARK: - REC-001: ordinary coverage edits keep curated automatic trips

    /// A completed automatic trip whose one stay is at the village.
    @discardableResult
    private func villageTrip(_ ctx: ModelContext, day: Double) -> Trip {
        let trip = Trip(startDate: date(day: day))
        trip.endDate = date(day: day + 0.5)
        trip.isComplete = true
        ctx.insert(trip)
        let stay = Stay(
            startTime: date(day: day), endTime: date(day: day).addingTimeInterval(4 * 3600),
            centroidLatitude: Self.village.lat, centroidLongitude: Self.village.lon,
            h3IndexRes6: "V", pingCount: 2, distanceFromHomeKm: 16, pingIDs: [])
        stay.category = .destination
        ctx.insert(stay)
        stay.trip = trip
        return trip
    }

    private func tripMembers(_ id: UUID, _ container: ModelContainer) throws -> [Stay] {
        try ModelContext(container).fetch(FetchDescriptor<Trip>(predicate: #Predicate { $0.id == id }))
            .flatMap { $0.stays ?? [] }
    }

    @Test("a Home whose ring grows over automatic trips keeps a favourite and a trip with a hidden photo whole, with their stays, and still absorbs the untouched one")
    func homeChangeKeepsCuratedTrips() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let home = Home(label: "Home", latitude: Self.home.lat, longitude: Self.home.lon,
                        radiusKm: 25, startedAt: date(day: 0))
        ctx.insert(home)
        let favourite = villageTrip(ctx, day: 5)
        let hidden = villageTrip(ctx, day: 10)
        ctx.insert(HiddenPhoto(localIdentifier: "asset-1", tripID: hidden.id))
        let untouched = villageTrip(ctx, day: 15)
        try ctx.save()
        let (favouriteID, hiddenID, untouchedID) = (favourite.id, hidden.id, untouched.id)

        let classifier = TripClassifier(modelContainer: container)
        let outcome = await classifier.applyHomeChangeCore(
            homeID: home.id, backdatesStart: false, pinnedTripIDs: [favouriteID])
        #expect(outcome.resetCount == 1)
        for id in [favouriteID, hiddenID] {
            let members = try tripMembers(id, container)
            #expect(members.count == 1)
            #expect(members.allSatisfy { $0.category == .destination })
        }
        #expect(try tripMembers(untouchedID, container).isEmpty)
        #expect(try ModelContext(container).fetch(FetchDescriptor<Trip>()).count == 2)
    }

    @Test("a Home grown over a favourite automatic open trip keeps it through the follow-up pipeline and the next ordinary pass, with its stay and id, while the untouched trip it covers is absorbed")
    func homeChangeKeepsCuratedOpenTripThroughPipeline() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let home = Home(label: "Home", latitude: Self.home.lat, longitude: Self.home.lon,
                        radiusKm: 25, startedAt: date(day: 0))
        ctx.insert(home)
        let untouched = villageTrip(ctx, day: 5)
        // The journey still under way, at the village.
        let favourite = villageTrip(ctx, day: 20)
        favourite.endDate = nil
        favourite.isComplete = false
        try ctx.save()
        let (favouriteID, untouchedID) = (favourite.id, untouched.id)
        let favouriteStayIDs = Set(try tripMembers(favouriteID, container).map(\.id))

        let classifier = TripClassifier(modelContainer: container)
        // Still a favourite for every pass below, so the coverage mark holds.
        await classifier.runIsolated { $0.pinnedTripIDsSource = { [favouriteID] } }
        // The grown area: a seed that reaches the village.
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: HomeShape.urbanCentre(
                id: 2, name: "Wide", areaKm2: 900,
                rings: [[[Self.home.lon - 0.3, Self.home.lat - 0.3, Self.home.lon + 0.3, Self.home.lat - 0.3,
                          Self.home.lon + 0.3, Self.home.lat + 0.3, Self.home.lon - 0.3, Self.home.lat + 0.3]]],
                centreLatitude: Self.home.lat, centreLongitude: Self.home.lon))
        let outcome = await classifier.applyHomeChange(
            homeID: home.id, backdatesStart: false, gate: PipelineGate(forTesting: ()),
            pinnedTripIDs: { [favouriteID] })
        #expect(outcome == .committed(resetCount: 1))

        func expectFavouriteWhole() throws {
            let rows = try ModelContext(container).fetch(FetchDescriptor<Trip>(
                predicate: #Predicate { $0.id == favouriteID }))
            #expect(rows.count == 1)
            #expect(rows.first?.userEdited == true)
            let members = rows.flatMap { $0.stays ?? [] }
            #expect(Set(members.map(\.id)) == favouriteStayIDs)
            #expect(members.allSatisfy { $0.category == .destination })
        }
        try expectFavouriteWhole()
        #expect(try tripMembers(untouchedID, container).isEmpty)
        // The mark is logged as the coverage edit's, so it can go with the favourite.
        #expect(TripClassifier.sparedTrips(defaults: IsolatedTitleDefaults.current)
            == [favouriteID: favouriteStayIDs])

        _ = await classifier.classifyAndAssembleTripsReportingChangesWithGates(
            gate: PipelineGate(forTesting: ()))
        try expectFavouriteWhole()
    }

    @Test("a routine place grown over automatic trips keeps a named one and one with a pinned photo, and still absorbs the untouched one")
    func routineChangeKeepsCuratedTrips() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        ctx.insert(Home(label: "Home", latitude: Self.home.lat, longitude: Self.home.lon,
                        radiusKm: 1, startedAt: date(day: 0)))
        let place = RoutinePlace(label: "Gym", latitude: Self.village.lat, longitude: Self.village.lon,
                                 radiusMeters: 2000, startedAt: date(day: 0))
        ctx.insert(place)
        let named = villageTrip(ctx, day: 5)
        named.customName = "Climbing weekend"
        let pinned = villageTrip(ctx, day: 10)
        ctx.insert(PinnedPhoto(localIdentifier: "asset-2", tripID: pinned.id))
        let untouched = villageTrip(ctx, day: 15)
        try ctx.save()
        let (namedID, pinnedID, untouchedID) = (named.id, pinned.id, untouched.id)

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.applyRoutinePlaceChangeCoreForTesting(placeID: place.id)
                == .committed(resetCount: 1))
        #expect(try tripMembers(namedID, container).count == 1)
        #expect(try tripMembers(pinnedID, container).count == 1)
        #expect(try tripMembers(untouchedID, container).isEmpty)
    }

    // MARK: - HOME-003: the receiving device frees stays no place claims any more

    @Test("home and routine stays another device's edit left claimed by no place are found and freed here, and a second look finds none; a stay a place still claims, one in a trip and one the user set stay")
    func receivedCoverageFreesStaleStays() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // The Home as another device moved it: 30 km north of where this
        // device's old home stays were recorded.
        let moved = (lat: Self.home.lat + 0.3, lon: Self.home.lon)
        ctx.insert(Home(label: "Home", latitude: moved.lat, longitude: moved.lon,
                        radiusKm: 1, startedAt: date(day: 0)))
        // A routine place another device shrank to 100 m.
        ctx.insert(RoutinePlace(label: "Gym", latitude: Self.village.lat, longitude: Self.village.lon,
                                radiusMeters: 100, startedAt: date(day: 0)))
        func stay(_ place: (lat: Double, lon: Double), day: Double, _ category: StayCategory) -> Stay {
            let stay = Stay(
                startTime: date(day: day), endTime: date(day: day).addingTimeInterval(6 * 3600),
                centroidLatitude: place.lat, centroidLongitude: place.lon,
                h3IndexRes6: "S", pingCount: 2, distanceFromHomeKm: 0, pingIDs: [])
            stay.category = category
            ctx.insert(stay)
            return stay
        }
        let oldHome = stay(Self.home, day: 5, .home)
        let stillHome = stay(moved, day: 6, .home)
        let oldRoutine = stay((Self.village.lat + 0.004, Self.village.lon), day: 7, .routine)
        let stillRoutine = stay(Self.village, day: 8, .routine)
        let userSet = stay(Self.home, day: 9, .home)
        userSet.userOverridden = true
        let inTrip = stay(Self.home, day: 10, .home)
        let trip = Trip(startDate: date(day: 10))
        ctx.insert(trip)
        inTrip.trip = trip
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: moved.lat, longitude: moved.lon,
            shape: TemporaryHomeFixture.squareShape(id: 2, around: moved))
        #expect(await classifier.hasStaleOrdinaryPlaceStays() == true)
        #expect(await classifier.staleOrdinaryPlaceStayCount(release: true) == 2)
        #expect(await classifier.hasStaleOrdinaryPlaceStays() == false)

        let check = ModelContext(container)
        func category(_ stay: Stay) throws -> StayCategory? {
            let id = stay.id
            return try check.fetch(FetchDescriptor<Stay>(predicate: #Predicate { $0.id == id })).first?.category
        }
        #expect(try category(oldHome) == .unclassified)
        #expect(try category(oldRoutine) == .unclassified)
        #expect(try category(stillHome) == .home)
        #expect(try category(stillRoutine) == .routine)
        #expect(try category(userSet) == .home)
        #expect(try category(inTrip) == .home)
    }

    // MARK: - HOME-002: the gate's prehistory pass drops taught includes

    @Test("a group predating every home is scored without the home's timeless taught includes, as classification judged it, while a group in the home's era keeps them")
    func prehistoryGateDropsTaughtIncludes() {
        let include = (latitude: Self.village.lat, longitude: Self.village.lon, radiusKm: 2.0)
        var ring = TripClassifier.HomeRing(
            latitude: Self.home.lat, longitude: Self.home.lon, radiusKm: 25,
            startedAt: date(day: 100), endedAt: nil)
        ring = ring.withMembership(HomeMembership(seed: Self.squareShape(), includeDiscs: [include]))
        let historic = date(day: 10)
        let prehistory = TripClassifier.gateMemberships(stayStarts: [historic], rings: [ring])
        #expect(prehistory.count == 1)
        #expect(prehistory.allSatisfy { !$0.contains(
            latitude: Self.village.lat, longitude: Self.village.lon, at: historic) })
        // Classification agrees: the historic stay there is not home.
        #expect(!TripClassifier.matchesHome(
            stayStart: historic, latitude: Self.village.lat, longitude: Self.village.lon, homes: [ring]))
        // The seed still claims its own history.
        #expect(prehistory.allSatisfy { $0.contains(
            latitude: Self.home.lat, longitude: Self.home.lon, at: historic) })

        let inEra = date(day: 120)
        let current = TripClassifier.gateMemberships(stayStarts: [inEra], rings: [ring])
        #expect(current.contains { $0.contains(
            latitude: Self.village.lat, longitude: Self.village.lon, at: inEra) })
    }

    // MARK: - HOME-001: orbit clustering links every pair within a kilometre

    @Test("observations within a kilometre are one cluster wherever they lie: far north, across the antimeridian and near a pole; two more than a kilometre apart stay two",
          arguments: [((60.0, 170.0), (60.008, 170.0)),
                      ((10.0, 179.999), (10.0, -179.999)),
                      ((89.999, 0.0), (89.999, 90.0)),
                      ((44.3, 12.9), (44.3, 12.91))])
    func orbitClustersLinkEveryNearPair(pair: ((Double, Double), (Double, Double))) {
        func observation(_ point: (Double, Double), hour: Double) -> HomeOrbit.StayObservation {
            HomeOrbit.StayObservation(
                id: UUID(), start: date(day: 1).addingTimeInterval(hour * 3600),
                end: date(day: 1).addingTimeInterval((hour + 1) * 3600),
                latitude: point.0, longitude: point.1, isTransitNode: false, isLive: true)
        }
        let (a, b) = pair
        #expect(HomeOrbit.greatCircleKm(a.0, a.1, b.0, b.1) <= HomeOrbit.linkRadiusKm)
        #expect(HomeOrbit.clusters(from: [observation(a, hour: 1), observation(b, hour: 3)]).count == 1)
        let far = (a.0 - 0.02, a.1)
        #expect(HomeOrbit.greatCircleKm(a.0, a.1, far.0, far.1) > HomeOrbit.linkRadiusKm)
        #expect(HomeOrbit.clusters(from: [observation(a, hour: 1), observation(far, hour: 3)]).count == 2)
    }

    // MARK: - HOME-004: distance to a home shape measures to its holes too

    @Test("a point in a hole of a home shape is as far as the hole's edge, not the outer edge; inside the shape is zero and outside is unchanged")
    func homeShapeDistanceMeasuresHoles() {
        let (lat, lon) = Self.home
        func square(_ half: Double) -> [Double] {
            [lon - half, lat - half, lon + half, lat - half,
             lon + half, lat + half, lon - half, lat + half]
        }
        let donut = HomeShape.urbanCentre(
            id: 9, name: "Ring Town", areaKm2: 200, rings: [[square(0.1), square(0.05)]],
            centreLatitude: lat, centreLongitude: lon)
        let kmPerDegree = 6_371.0088 * Double.pi / 180
        let holeEdgeKm = 0.05 * kmPerDegree * cos(lat * .pi / 180)
        #expect(!donut.contains(latitude: lat, longitude: lon))
        #expect(abs(donut.distanceKm(toLatitude: lat, longitude: lon) - holeEdgeKm) < 0.01)
        #expect(donut.distanceKm(toLatitude: lat, longitude: lon + 0.075) == 0)
        let outerEdgeKm = 0.05 * kmPerDegree * cos(lat * .pi / 180)
        #expect(abs(donut.distanceKm(toLatitude: lat, longitude: lon + 0.15) - outerEdgeKm) < 0.01)
    }

    // MARK: - ID-005: routine dedup never shrinks routine coverage

    @Test("a nearby duplicate routine place whose area reaches past the survivor's is kept, so a stay in its fringe stays covered; one whose area nests in the survivor's collapses into it")
    func routineDedupKeepsAnOffsetDonor() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let survivor = RoutinePlace(label: "Office", latitude: Self.village.lat, longitude: Self.village.lon,
                                    radiusMeters: 500, startedAt: date(day: 0))
        survivor.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        // 200 m north, same radius: its northern fringe is outside the survivor's disc.
        let offset = RoutinePlace(label: "Office", latitude: Self.village.lat + 0.0018,
                                  longitude: Self.village.lon, radiusMeters: 500, startedAt: date(day: 0))
        offset.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        // 50 m east and 100 m wide: wholly inside the survivor's disc.
        let nested = RoutinePlace(label: "Office", latitude: Self.village.lat,
                                  longitude: Self.village.lon + 0.0006, radiusMeters: 100, startedAt: date(day: 0))
        nested.id = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        for place in [survivor, offset, nested] { ctx.insert(place) }
        try ctx.save()
        let (lat, lon) = (Self.village.lat + 0.0018 + 0.004, Self.village.lon)
        let rings = { (places: [RoutinePlace]) in places.map {
            TripClassifier.RoutineRing(latitude: $0.latitude, longitude: $0.longitude,
                                       radiusMeters: $0.radiusMeters, startedAt: $0.startedAt,
                                       endedAt: $0.endedAt)
        } }
        let fringe = date(day: 5)
        let before = try ModelContext(container).fetch(FetchDescriptor<RoutinePlace>())
        #expect(TripClassifier.matchesRoutine(stayStart: fringe, latitude: lat, longitude: lon,
                                              places: rings(before)))

        await PlacesDeduplicator.deduplicateAll(modelContainer: container, defaults: defaults)
        let after = try ModelContext(container).fetch(FetchDescriptor<RoutinePlace>())
        #expect(Set(after.map(\.id)) == [survivor.id, offset.id] as Set<UUID>)
        #expect(TripClassifier.matchesRoutine(stayStart: fringe, latitude: lat, longitude: lon,
                                              places: rings(after)))
    }

    // MARK: - NOTE-003: unreadable Homes are no evidence for Welcome Home

    @Test("Welcome Home's home check throws when the Homes cannot be read, rather than calling the user away, and answers again once they can")
    func welcomeHomeCheckFailsOnUnreadableHomes() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        ctx.insert(Home(label: "Home", latitude: Self.home.lat, longitude: Self.home.lon,
                        radiusKm: 25, startedAt: date(day: 0)))
        try ctx.save()
        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon, shape: Self.squareShape())

        classifier.failHomeReadForTesting = true
        await #expect(throws: (any Error).self) {
            _ = try await classifier.currentHomeSeedCovers(latitude: Self.home.lat, longitude: Self.home.lon)
        }
        classifier.failHomeReadForTesting = false
        #expect(try await classifier.currentHomeSeedCovers(latitude: Self.home.lat, longitude: Self.home.lon))
        #expect(try await classifier.currentHomeSeedCovers(
            latitude: Self.village.lat, longitude: Self.village.lon) == false)
    }
}

// The drain's state is process-wide: its tests run in the serialized drain suite.
extension ReconciliationDrainTests {
@MainActor
@Suite("P04 received coverage drain", IsolatedTitleDefaults())
struct P04DrainTests {

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "P04DrainTests-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    @MainActor
    private final class DrainProbe {
        var released = 0
        var published = 0
        var heals = 0
    }

    private func drainStages(_ probe: DrainProbe, stale: Bool?) -> CoverageReconciliationQueue.Stages {
        var stages = CoverageReconciliationQueue.Stages(
            applyHome: { _, _ in .committed(resetCount: 0) },
            applyRoutinePlace: { _, _ in .committed(resetCount: 0) },
            generateLocalizedTitles: {},
            publish: { _, _ in probe.published += 1 },
            heal: { probe.heals += 1 },
            isPersistentStore: { true })
        stages.staleOrdinaryPlaceStays = { stale }
        stages.releaseStaleOrdinaryPlaceStays = {
            probe.released += 1
            return .committed(resetCount: 2)
        }
        return stages
    }

    @Test("a drain with nothing queued still frees stale home and routine stays, publishes and heals; an unreadable look leaves the drain unsettled and frees nothing")
    func drainRunsReceivedCoverageRepair() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = DrainProbe()
        #expect(await CoverageReconciliationQueue.drainIfNeeded(
            defaults: defaults, stages: drainStages(probe, stale: true)))
        #expect(probe.released == 1 && probe.published == 1 && probe.heals == 1)

        #expect(await CoverageReconciliationQueue.drainIfNeeded(
            defaults: defaults, stages: drainStages(probe, stale: false)))
        #expect(probe.released == 1)

        #expect(!(await CoverageReconciliationQueue.drainIfNeeded(
            defaults: defaults, stages: drainStages(probe, stale: nil))))
        #expect(probe.released == 1)
    }
}
}
