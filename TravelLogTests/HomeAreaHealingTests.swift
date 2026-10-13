//
//  HomeAreaHealingTests.swift
//  TravelLogTests
//
//  Retroactive healing: after a correction
//  changes home-area membership, completed trips the new membership claims
//  ENTIRELY dissolve — unless the user ever interacted with them. Pins:
//
//  - one correction heals every trip in the same place;
//  - the interaction guard, case by case, and its current case count;
//  - the one-directional rule (a trip with any out-of-membership stay is
//    untouched — healing dissolves, never re-cuts);
//  - the fingerprint (moves on override add/remove, stable otherwise).
//
//  Same square-urban-centre harness as CorrectionChannelTests.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
struct HomeAreaHealingTests {

    private enum InjectedQueueError: Error { case writeFailed }

    private final class FinalizationCounter {
        var outcome: TripClassifier.HomeAreaHealingOutcome?
        var healCalls = 0
        var classified = 0
        var generatedTitles = 0
        var coverageCalls = 0
        var changeBumps = 0
        var widgetReloads = 0
    }

    private static let day: TimeInterval = 24 * 60 * 60
    private static let home = (lat: 38.0, lon: 23.8)
    private static let village = (lat: 38.0, lon: 23.99)

    private func date(day offset: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: (offset - 273) * Self.day)
    }

    private static func squareShape() -> HomeShape {
        HomeShape.urbanCentre(
            id: 1, name: "TestCity", areaKm2: 100,
            rings: [[[23.75, 37.95, 23.85, 37.95, 23.85, 38.05, 23.75, 38.05]]],
            centreLatitude: home.lat, centreLongitude: home.lon)
    }

    @discardableResult
    private func makeVillageTrip(
        in ctx: ModelContext, startDay: Double,
        userEdited: Bool = false, customName: String? = nil,
        stayOverridden: Bool = false
    ) -> Trip {
        let trip = Trip(startDate: date(day: startDay))
        trip.endDate = date(day: startDay + 0.5)
        trip.isComplete = true
        trip.userEdited = userEdited
        trip.customName = customName
        ctx.insert(trip)
        let start = date(day: startDay)
        let stay = Stay(
            startTime: start, endTime: start.addingTimeInterval(4 * 3600),
            centroidLatitude: Self.village.lat, centroidLongitude: Self.village.lon,
            h3IndexRes6: "V", pingCount: 2, distanceFromHomeKm: 17, pingIDs: [])
        stay.category = .destination
        stay.userOverridden = stayOverridden
        ctx.insert(stay)
        stay.trip = trip
        return trip
    }

    private func makeHomeRow(in ctx: ModelContext) -> Home {
        let home = Home(label: "Home", latitude: Self.home.lat,
                        longitude: Self.home.lon, radiusKm: 25,
                        startedAt: date(day: -100))
        ctx.insert(home)
        return home
    }

    private func addIncludeOverride(in ctx: ModelContext, homeID: UUID) {
        ctx.insert(HomeAreaOverride(
            kind: .include, centerLatitude: Self.village.lat,
            centerLongitude: Self.village.lon, radiusKm: 1, homeID: homeID))
    }

    // MARK: - The class heal

    @Test("one include disc dissolves every non-interacted twin trip at that cluster")
    func oneCorrectionHealsTheClass() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let home = makeHomeRow(in: ctx)
        for day in [0.0, 10, 20] { makeVillageTrip(in: ctx, startDay: day) }
        addIncludeOverride(in: ctx, homeID: home.id)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        let dissolved = await classifier.healHomeAreaCorrections(pinnedTripIDs: [])
        #expect(dissolved.moved == 3)
        #expect(!dissolved.failed)
        #expect(try ctx.fetch(FetchDescriptor<Trip>()).isEmpty)
        // Freed stays are unclassified — the next pipeline pass re-stamps
        // them .home through the normal path (never re-minted from here).
        for stay in try ctx.fetch(FetchDescriptor<Stay>()) {
            #expect(stay.category == .unclassified)
            #expect(stay.trip == nil)
        }
    }

    @Test("every interaction protects a trip from healing",
          arguments: TripClassifier.TripInteraction.allCases)
    func interactionGuard(interaction: TripClassifier.TripInteraction) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let home = makeHomeRow(in: ctx)
        let trip = makeVillageTrip(
            in: ctx, startDay: 0,
            userEdited: interaction == .userEdited,
            customName: interaction == .customName ? "Kept" : nil,
            stayOverridden: interaction == .stayOverridden)
        switch interaction {
        case .hiddenPhoto:
            let hidden = HiddenPhoto(localIdentifier: "asset-1", tripID: trip.id)
            ctx.insert(hidden)
        case .pinnedPhoto:
            let pinned = PinnedPhoto(localIdentifier: "asset-2", tripID: trip.id)
            ctx.insert(pinned)
        default: break
        }
        addIncludeOverride(in: ctx, homeID: home.id)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        let pinnedIDs: Set<UUID> = interaction == .pinned ? [trip.id] : []
        let dissolved = await classifier.healHomeAreaCorrections(
            pinnedTripIDs: pinnedIDs)
        #expect(dissolved.moved == 0)
        #expect(!dissolved.failed)
        #expect(try ctx.fetch(FetchDescriptor<Trip>()).count == 1)
    }

    @Test("the interaction enum has six cases and an unengaged trip has no interactions")
    func interactionCaseCountAndEmptyInput() {
        // Check the current case count and the result for an unengaged trip.
        #expect(TripClassifier.TripInteraction.allCases.count == 6)
        #expect(TripClassifier.interactions(
            userEdited: false, hasCustomName: false, isPinned: false,
            hasHiddenPhoto: false, hasPinnedPhoto: false,
            hasOverriddenStay: false).isEmpty)
    }

    @Test("a trip with any stay beyond membership is untouched (healing never re-cuts)")
    func partialClaimIsUntouched() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let home = makeHomeRow(in: ctx)
        let trip = makeVillageTrip(in: ctx, startDay: 0)
        // Second stay far beyond the include disc AND the seed.
        let far = Stay(
            startTime: date(day: 0.2), endTime: date(day: 0.3),
            centroidLatitude: 38.9, centroidLongitude: 24.55,
            h3IndexRes6: "F", pingCount: 2, distanceFromHomeKm: 120, pingIDs: [])
        far.category = .destination
        ctx.insert(far)
        far.trip = trip
        addIncludeOverride(in: ctx, homeID: home.id)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        #expect((await classifier.healHomeAreaCorrections(
            pinnedTripIDs: [])).moved == 0)
        #expect(try ctx.fetch(FetchDescriptor<Trip>()).count == 1)
    }

    @Test("healing preserves the trip when its recovery record cannot be persisted")
    func healingQueueFailurePreservesTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let home = makeHomeRow(in: ctx)
        let trip = makeVillageTrip(in: ctx, startDay: 0)
        let tripID = trip.id
        let stayID = try #require(trip.stays?.first?.id)
        addIncludeOverride(in: ctx, homeID: home.id)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        await classifier.setDissolvedRecordSink { _ in
            throw InjectedQueueError.writeFailed
        }

        let outcome = await classifier.healHomeAreaCorrections(
            pinnedTripIDs: [])
        #expect(outcome.moved == 0)
        #expect(outcome.failed,
                "the trigger must distinguish rollback from a successful no-op")
        #expect(await classifier.drainParkedDissolvedTrips().isEmpty)

        let verification = ModelContext(container)
        let restoredTrip = try #require(try verification.fetch(
            FetchDescriptor<Trip>()).first { $0.id == tripID })
        let restoredStay = try #require(try verification.fetch(
            FetchDescriptor<Stay>()).first { $0.id == stayID })
        #expect(restoredStay.trip === restoredTrip)
        #expect(restoredStay.category == .destination)
    }

    @Test("a healing fetch failure after staged mutations rolls back and reports failure")
    func healingFetchFailureRollsBackAndReportsFailure() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let home = makeHomeRow(in: context)
        let trip = makeVillageTrip(in: context, startDay: 0)
        let tripID = trip.id
        let stayID = try #require(trip.stays?.first?.id)
        addIncludeOverride(in: context, homeID: home.id)
        try context.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        // Home, hidden-photo, pinned-photo, and Trip fetches succeed. The
        // residue fetch fails after the Trip has been staged for dissolution.
        await classifier.failHomeAreaHealingFetchCallForTesting(5)

        let outcome = await classifier.healHomeAreaCorrections(
            pinnedTripIDs: [])
        #expect(outcome.moved == 0)
        #expect(outcome.failed)

        let verification = ModelContext(container)
        let restoredTrip = try #require(try verification.fetch(
            FetchDescriptor<Trip>()).first { $0.id == tripID })
        let restoredStay = try #require(try verification.fetch(
            FetchDescriptor<Stay>()).first { $0.id == stayID })
        #expect(restoredStay.trip === restoredTrip)
        #expect(restoredStay.category == .destination)
    }

    @Test("coverage override fetch failure leaves coverage and fingerprint stamps untouched")
    func coverageFetchFailureLeavesAllStampsUntouched() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let classifier = TripClassifier(modelContainer: container)
        let suiteName = "HomeAreaCoverageFailure-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let staleCoverage = try JSONEncoder().encode([
            TripClassifier.CoverageDisc(
                latitude: Self.village.lat,
                longitude: Self.village.lon,
                radiusKm: 1),
        ])
        let staleStamp = Date(timeIntervalSinceReferenceDate: -23587077)
        defaults.set("stale-fingerprint", forKey: HomeAreaHealing.fingerprintKey)
        defaults.set(staleCoverage, forKey: HomeAreaHealing.coverageKey)
        defaults.set(staleStamp, forKey: HomeAreaHealing.coverageStampedAtKey)
        let counter = FinalizationCounter()
        let stages = HomeAreaHealing.Stages(
            rescue: {},
            fingerprint: { "current-fingerprint" },
            heal: { _ in
                await classifier.failHomeAreaHealingFetchCallForTesting(1)
                return TripClassifier.HomeAreaHealingOutcome(
                    moved: 0, failed: false)
            },
            drainParked: { [] },
            classify: { counter.classified += 1; return true },
            generateTitles: { counter.generatedTitles += 1 },
            coverage: {
                counter.coverageCalls += 1
                return try await classifier.homeAreaCoverage()
            },
            bumpChanges: { counter.changeBumps += 1 },
            reloadWidgets: { counter.widgetReloads += 1 })

        await HomeAreaHealing.healIfNeeded(
            defaults: defaults, stages: stages)

        #expect(counter.classified == 1)
        #expect(counter.generatedTitles == 1)
        #expect(counter.coverageCalls == 1)
        #expect(defaults.string(forKey: HomeAreaHealing.fingerprintKey)
                == "stale-fingerprint")
        #expect(defaults.data(forKey: HomeAreaHealing.coverageKey)
                == staleCoverage)
        #expect(defaults.object(forKey: HomeAreaHealing.coverageStampedAtKey)
                as? Date == staleStamp)
    }

    @Test("an unreadable fingerprint heals and stamps nothing, and the next trigger still heals",
          arguments: [false, true])
    func unreadableFingerprintLeavesAllStampsUntouchedAndRetries(evidenceOnly: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let home = makeHomeRow(in: context)
        try context.save()
        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        let stamped = try #require(await classifier.homeAreaFingerprint())
        let suiteName = "HomeAreaFingerprintFailure-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let staleCoverage = try JSONEncoder().encode([
            TripClassifier.CoverageDisc(
                latitude: Self.village.lat,
                longitude: Self.village.lon,
                radiusKm: 1),
        ])
        let staleStamp = Date(timeIntervalSinceReferenceDate: -23587077)
        defaults.set(stamped, forKey: HomeAreaHealing.fingerprintKey)
        defaults.set(staleCoverage, forKey: HomeAreaHealing.coverageKey)
        defaults.set(staleStamp, forKey: HomeAreaHealing.coverageStampedAtKey)

        addIncludeOverride(in: context, homeID: home.id)
        try context.save()
        let counter = FinalizationCounter()
        let stages = HomeAreaHealing.Stages(
            rescue: {},
            fingerprint: { await classifier.homeAreaFingerprint() },
            heal: { _ in
                counter.healCalls += 1
                return .init(moved: 0, failed: false)
            },
            drainParked: { [] },
            classify: { counter.classified += 1; return true },
            generateTitles: {},
            coverage: {
                counter.coverageCalls += 1
                return []
            },
            bumpChanges: {},
            reloadWidgets: {})

        // Homes stay readable when only the orbit evidence fails.
        classifier.failHomeReadForTesting = !evidenceOnly
        classifier.failOrbitEvidenceReadForTesting = evidenceOnly
        #expect(await classifier.homeAreaFingerprint() == nil)
        #expect(await HomeAreaHealing.healIfNeeded(defaults: defaults, stages: stages) == false)
        #expect(counter.healCalls == 0)
        #expect(counter.classified == 0)
        #expect(counter.coverageCalls == 0)
        #expect(defaults.string(forKey: HomeAreaHealing.fingerprintKey) == stamped)
        #expect(defaults.data(forKey: HomeAreaHealing.coverageKey) == staleCoverage)
        #expect(defaults.object(forKey: HomeAreaHealing.coverageStampedAtKey)
                as? Date == staleStamp)

        classifier.failHomeReadForTesting = false
        classifier.failOrbitEvidenceReadForTesting = false
        #expect(await HomeAreaHealing.healIfNeeded(defaults: defaults, stages: stages))
        #expect(counter.healCalls == 1)
        let updated = try #require(defaults.string(forKey: HomeAreaHealing.fingerprintKey))
        #expect(updated != stamped)
    }

    @Test("a failure after one shrink commit finalizes committed work without stamping")
    func partialShrinkFailureRunsFinalizationWithoutStamps() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        _ = makeHomeRow(in: context)
        let staleDiscs = [
            TripClassifier.CoverageDisc(
                latitude: Self.village.lat,
                longitude: Self.village.lon,
                radiusKm: 1),
            TripClassifier.CoverageDisc(
                latitude: Self.village.lat,
                longitude: 24.05,
                radiusKm: 1),
        ]
        for (index, disc) in staleDiscs.enumerated() {
            let stay = Stay(
                startTime: date(day: Double(index)),
                endTime: date(day: Double(index) + 0.25),
                centroidLatitude: disc.latitude,
                centroidLongitude: disc.longitude,
                h3IndexRes6: "partial-\(index)", pingCount: 2,
                distanceFromHomeKm: 17, pingIDs: [])
            stay.category = .home
            context.insert(stay)
        }
        try context.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        // Five pre-shrink fetches, then Home + Stay for the first disc. The
        // second disc's Home fetch fails after the first disc's save landed.
        await classifier.failHomeAreaHealingFetchCallForTesting(8)

        let suiteName = "HomeAreaPartialFailure-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let staleCoverage = try JSONEncoder().encode(staleDiscs)
        let staleStamp = Date(timeIntervalSinceReferenceDate: -23586744)
        defaults.set("stale-fingerprint", forKey: HomeAreaHealing.fingerprintKey)
        defaults.set(staleCoverage, forKey: HomeAreaHealing.coverageKey)
        defaults.set(staleStamp, forKey: HomeAreaHealing.coverageStampedAtKey)
        let counter = FinalizationCounter()
        let stages = HomeAreaHealing.Stages(
            rescue: {},
            fingerprint: { "current-fingerprint" },
            heal: { staleCoverage in
                let outcome = await classifier.healHomeAreaCorrections(
                    pinnedTripIDs: [],
                    staleCoverage: staleCoverage)
                counter.outcome = outcome
                return outcome
            },
            drainParked: {
                await classifier.drainParkedDissolvedTrips()
            },
            classify: { counter.classified += 1; return true },
            generateTitles: { counter.generatedTitles += 1 },
            coverage: {
                counter.coverageCalls += 1
                return []
            },
            bumpChanges: { counter.changeBumps += 1 },
            reloadWidgets: { counter.widgetReloads += 1 })

        await HomeAreaHealing.healIfNeeded(
            defaults: defaults, stages: stages)

        #expect(counter.outcome == TripClassifier.HomeAreaHealingOutcome(
            moved: 1, failed: true))
        let categories = try ModelContext(container)
            .fetch(FetchDescriptor<Stay>()).map(\.category)
        #expect(categories.filter { $0 == .unclassified }.count == 1)
        #expect(categories.filter { $0 == .home }.count == 1)
        #expect(counter.classified == 1)
        #expect(counter.generatedTitles == 1)
        #expect(counter.coverageCalls == 0)
        #expect(counter.changeBumps == 2)
        #expect(counter.widgetReloads == 1)
        #expect(defaults.string(forKey: HomeAreaHealing.fingerprintKey)
                == "stale-fingerprint")
        #expect(defaults.data(forKey: HomeAreaHealing.coverageKey)
                == staleCoverage)
        #expect(defaults.object(forKey: HomeAreaHealing.coverageStampedAtKey)
                as? Date == staleStamp)
    }

    @Test("manual demotion preserves the trip when its recovery record cannot be persisted")
    func demotionQueueFailurePreservesTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        _ = makeHomeRow(in: ctx)
        let trip = makeVillageTrip(in: ctx, startDay: 0)
        let tripID = trip.id
        let stayID = try #require(trip.stays?.first?.id)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.setDissolvedRecordSink { _ in
            throw InjectedQueueError.writeFailed
        }

        #expect(await classifier.demoteSeededTrip(tripID) == .failed)
        #expect(await classifier.drainParkedDissolvedTrips().isEmpty)

        let verification = ModelContext(container)
        let restoredTrip = try #require(try verification.fetch(
            FetchDescriptor<Trip>()).first { $0.id == tripID })
        let restoredStay = try #require(try verification.fetch(
            FetchDescriptor<Stay>()).first { $0.id == stayID })
        #expect(restoredStay.trip === restoredTrip)
        #expect(restoredStay.category == .destination)
        #expect(try verification.fetch(
            FetchDescriptor<HomeAreaOverride>()).isEmpty)
    }

    // MARK: - Growth direction, part two: residue conversion

    @Test("suppressed residue at a spot that became home converts to home, not phantom outings")
    func residueConvertsWhenMembershipClaims() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let home = makeHomeRow(in: ctx)
        // A tripless suppressed destination stay at the village…
        let residue = Stay(
            startTime: date(day: 0), endTime: date(day: 0).addingTimeInterval(2 * 3600),
            centroidLatitude: Self.village.lat, centroidLongitude: Self.village.lon,
            h3IndexRes6: "R", pingCount: 2, distanceFromHomeKm: 17, pingIDs: [])
        residue.category = .destination
        ctx.insert(residue)
        // …and the village later taught into the home area.
        addIncludeOverride(in: ctx, homeID: home.id)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        let healed = await classifier.healHomeAreaCorrections(pinnedTripIDs: [])
        #expect(healed.moved == 1)
        let stay = try #require(try ctx.fetch(FetchDescriptor<Stay>()).first)
        #expect(stay.category == .unclassified,
                "freed for the pipeline to re-stamp .home — never a direct stamp")
        // A residue stay marked userOverridden by Log as a Trip is protected.
        stay.category = .destination
        stay.userOverridden = true
        try ctx.save()
        #expect((await classifier.healHomeAreaCorrections(
            pinnedTripIDs: [])).moved == 0)
    }

    // MARK: - Learned orbits need a witnessed return home

    @discardableResult
    private func insertLiveStay(
        in ctx: ModelContext, day: Double, hour: Double, hours: Double,
        at place: (lat: Double, lon: Double), category: StayCategory,
        overridden: Bool = false, completedTrip: Bool = false
    ) -> Stay {
        let start = date(day: day).addingTimeInterval(hour * 3600)
        let stay = Stay(
            startTime: start, endTime: start.addingTimeInterval(hours * 3600),
            centroidLatitude: place.lat, centroidLongitude: place.lon,
            h3IndexRes6: "L", pingCount: 2, distanceFromHomeKm: 17, pingIDs: [])
        stay.category = category
        stay.userOverridden = overridden
        ctx.insert(stay)
        if completedTrip {
            let trip = Trip(startDate: start)
            trip.endDate = stay.endTime
            trip.isComplete = true
            ctx.insert(trip)
            stay.trip = trip
        }
        return stay
    }

    /// Two witnessed same-day day trips to the village, then a third visit
    /// still open at the end of input: the user is there now.
    @discardableResult
    private func seedOpenThirdVisit(
        in ctx: ModelContext, thirdCategory: StayCategory
    ) -> Stay {
        _ = makeHomeRow(in: ctx)
        for day in [0.0, 10] {
            insertLiveStay(in: ctx, day: day, hour: 0, hours: 8,
                           at: Self.home, category: .home)
            insertLiveStay(in: ctx, day: day, hour: 10, hours: 4,
                           at: Self.village, category: .destination,
                           completedTrip: true)
            insertLiveStay(in: ctx, day: day, hour: 18, hours: 6,
                           at: Self.home, category: .home)
        }
        insertLiveStay(in: ctx, day: 20, hour: 0, hours: 8,
                       at: Self.home, category: .home)
        return insertLiveStay(in: ctx, day: 20, hour: 10, hours: 1,
                              at: Self.village, category: thirdCategory)
    }

    @Test("an unfinished third visit learns no orbit until the user is seen home again")
    func openVisitLearnsNoOrbitUntilReturn() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedOpenThirdVisit(in: ctx, thirdCategory: .unclassified)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        let open = await classifier.primedOrbitsForTesting()
        #expect(open.count == 1)
        #expect(open.values.allSatisfy { $0.isEmpty })
        #expect(await classifier.healHomeAreaCorrections(pinnedTripIDs: [])
                == TripClassifier.HomeAreaHealingOutcome(moved: 0, failed: false))
        #expect(try ModelContext(container).fetch(FetchDescriptor<Trip>()).count == 2)

        // The witnessed arrival home completes the third same-day return; the
        // same classifier re-derives instead of reusing its memo.
        insertLiveStay(in: ctx, day: 20, hour: 18, hours: 6,
                       at: Self.home, category: .home)
        try ctx.save()
        let closed = await classifier.primedOrbitsForTesting()
        let disc = try #require(closed.values.flatMap { $0 }.first)
        #expect(disc.returnTimes == [0.0, 10, 20].map {
            date(day: $0).addingTimeInterval(18 * 3600)
        })
        #expect(await classifier.healHomeAreaCorrections(pinnedTripIDs: [])
                == TripClassifier.HomeAreaHealingOutcome(moved: 2, failed: false))
        #expect(try ModelContext(container).fetch(FetchDescriptor<Trip>()).isEmpty)
    }

    @Test("upgrade: a disc learned from an unfinished visit shrinks through the real heal; sacred stays and trips stand")
    func upgradeShrinksUnwitnessedDisc() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // The previous rule admitted the village and stamped the ongoing
        // visit home; the user had also confirmed one stay there.
        let automatic = seedOpenThirdVisit(in: ctx, thirdCategory: .home)
        let sacred = insertLiveStay(in: ctx, day: 20, hour: 11, hours: 1,
                                    at: Self.village, category: .home,
                                    overridden: true)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        let suiteName = "HomeOrbitUpgrade-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("pre-upgrade-fingerprint", forKey: HomeAreaHealing.fingerprintKey)
        defaults.set(try JSONEncoder().encode([
            TripClassifier.CoverageDisc(
                latitude: Self.village.lat, longitude: Self.village.lon,
                radiusKm: 1),
        ]), forKey: HomeAreaHealing.coverageKey)
        let counter = FinalizationCounter()
        let stages = HomeAreaHealing.Stages(
            rescue: {},
            fingerprint: { await classifier.homeAreaFingerprint() },
            heal: { stale in
                counter.healCalls += 1
                let outcome = await classifier.healHomeAreaCorrections(
                    pinnedTripIDs: [], staleCoverage: stale)
                counter.outcome = outcome
                return outcome
            },
            drainParked: { await classifier.drainParkedDissolvedTrips() },
            classify: { counter.classified += 1; return true },
            generateTitles: {},
            coverage: { try await classifier.homeAreaCoverage() },
            bumpChanges: {},
            reloadWidgets: {})

        #expect(await HomeAreaHealing.healIfNeeded(defaults: defaults, stages: stages))
        #expect(counter.healCalls == 1)
        #expect(counter.outcome == TripClassifier.HomeAreaHealingOutcome(moved: 1, failed: false))
        #expect(counter.classified == 1)
        let stays = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        #expect(stays.first { $0.id == automatic.id }?.category == .unclassified)
        #expect(stays.first { $0.id == sacred.id }?.category == .home)
        #expect(try ModelContext(container).fetch(FetchDescriptor<Trip>()).count == 2)
        let coverage = try JSONDecoder().decode(
            [TripClassifier.CoverageDisc].self,
            from: try #require(defaults.data(forKey: HomeAreaHealing.coverageKey)))
        #expect(coverage.isEmpty)
        let current = await classifier.homeAreaFingerprint()
        #expect(defaults.string(forKey: HomeAreaHealing.fingerprintKey) == current)
    }

    // MARK: - Shrink direction: un-homing within a removed geometry

    // Removing a user-taught include also frees the overridden home stays
    // that trip demotion assigned inside it, so the pipeline can classify
    // them again. Stays claimed by the home seed remain unchanged.
    @Test("a shrink save failure rolls back freed stays and reports failure")
    func shrinkSaveFailureRollsBackAndReportsFailure() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        _ = makeHomeRow(in: context)
        let stay = Stay(
            startTime: date(day: 0),
            endTime: date(day: 0).addingTimeInterval(2 * 3600),
            centroidLatitude: Self.village.lat,
            centroidLongitude: Self.village.lon,
            h3IndexRes6: "V", pingCount: 2,
            distanceFromHomeKm: 17, pingIDs: [])
        stay.category = .home
        let stayID = stay.id
        context.insert(stay)
        try context.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        await classifier.failNextUnHomeStaysSaveForTesting()

        let outcome = await classifier.healHomeAreaCorrections(
            pinnedTripIDs: [],
            staleCoverage: [.init(
                latitude: Self.village.lat,
                longitude: Self.village.lon,
                radiusKm: 1)])
        #expect(outcome.moved == 0)
        #expect(outcome.failed)

        let verification = ModelContext(container)
        let restored = try #require(try verification.fetch(
            FetchDescriptor<Stay>()).first { $0.id == stayID })
        #expect(restored.category == .home)
    }

    private func insertStay(
        in ctx: ModelContext, tag: String, lat: Double, lon: Double,
        category: StayCategory = .home, overridden: Bool = false
    ) {
        let stay = Stay(
            startTime: date(day: 0), endTime: date(day: 0).addingTimeInterval(2 * 3600),
            centroidLatitude: lat, centroidLongitude: lon,
            h3IndexRes6: tag, pingCount: 2, distanceFromHomeKm: 17, pingIDs: [])
        stay.category = category
        stay.userOverridden = overridden
        ctx.insert(stay)
    }

    @Test("a shrink frees exactly the automatic .home stays inside each stale disc")
    func shrinkFreesExactDiscMembership() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        _ = makeHomeRow(in: ctx)
        let d2 = (lat: 38.2, lon: 23.99)
        insertStay(in: ctx, tag: "a", lat: Self.village.lat, lon: Self.village.lon)
        // Outside the 1 km radius, inside its lat/lon box.
        insertStay(in: ctx, tag: "b", lat: Self.village.lat + 0.007, lon: Self.village.lon + 0.009)
        insertStay(in: ctx, tag: "c", lat: Self.village.lat, lon: 25.0)
        insertStay(in: ctx, tag: "d", lat: d2.lat, lon: d2.lon)
        insertStay(in: ctx, tag: "e", lat: Self.village.lat, lon: Self.village.lon, overridden: true)
        insertStay(in: ctx, tag: "f", lat: Self.village.lat, lon: Self.village.lon, category: .destination)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        let outcome = await classifier.healHomeAreaCorrections(
            pinnedTripIDs: [],
            staleCoverage: [
                .init(latitude: Self.village.lat, longitude: Self.village.lon, radiusKm: 1),
                .init(latitude: d2.lat, longitude: d2.lon, radiusKm: 1)])
        #expect(outcome.moved == 2)
        #expect(!outcome.failed)

        let categories = Dictionary(uniqueKeysWithValues: try ModelContext(container)
            .fetch(FetchDescriptor<Stay>()).map { ($0.h3IndexRes6, $0.category) })
        #expect(categories["a"] == .unclassified)
        #expect(categories["b"] == .home)
        #expect(categories["c"] == .home)
        #expect(categories["d"] == .unclassified)
        #expect(categories["e"] == .home)
        #expect(categories["f"] == .destination)
    }

    @Test("un-homing reaches stays across the antimeridian and near the pole",
          arguments: [(179.995, -179.998, 38.0, 38.0), (0.0, 0.0, 89.5, 89.505)])
    func unHomeStaysEdgeGeometry(
        discLon: Double, stayLon: Double, discLat: Double, stayLat: Double
    ) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        _ = makeHomeRow(in: ctx)
        insertStay(in: ctx, tag: "x", lat: stayLat, lon: stayLon)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        let freed = try await classifier.unHomeStays(
            nearLatitude: discLat, longitude: discLon, radiusKm: 1)
        #expect(freed == 1)
        let stay = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>()).first)
        #expect(stay.category == .unclassified)
    }

    @Test("removing a user-taught include frees its home stays, including trip demotion overrides; seed-claimed stays stay")
    func removeOverrideFreesTaughtStays() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let home = makeHomeRow(in: ctx)
        let override = HomeAreaOverride(
            kind: .include, centerLatitude: Self.village.lat,
            centerLongitude: Self.village.lon, radiusKm: 1, homeID: home.id)
        ctx.insert(override)
        // A stay the include had claimed (village, .home, automatic)…
        let claimed = Stay(
            startTime: date(day: 0), endTime: date(day: 0).addingTimeInterval(2 * 3600),
            centroidLatitude: Self.village.lat, centroidLongitude: Self.village.lon,
            h3IndexRes6: "V", pingCount: 2, distanceFromHomeKm: 17, pingIDs: [])
        claimed.category = .home
        ctx.insert(claimed)
        // An overridden village home stay assigned by trip demotion must
        // be freed with the teaching that created it.
        let sacred = Stay(
            startTime: date(day: 1), endTime: date(day: 1).addingTimeInterval(2 * 3600),
            centroidLatitude: Self.village.lat, centroidLongitude: Self.village.lon,
            h3IndexRes6: "S", pingCount: 2, distanceFromHomeKm: 17, pingIDs: [])
        sacred.category = .home
        sacred.userOverridden = true
        ctx.insert(sacred)
        // …and a downtown home stay that no include removal may ever touch.
        let downtown = Stay(
            startTime: date(day: 2), endTime: date(day: 2).addingTimeInterval(2 * 3600),
            centroidLatitude: Self.home.lat, centroidLongitude: Self.home.lon,
            h3IndexRes6: "D", pingCount: 2, distanceFromHomeKm: 0, pingIDs: [])
        downtown.category = .home
        ctx.insert(downtown)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        #expect(await classifier.removeOverride(id: override.id))

        let stays = try ctx.fetch(FetchDescriptor<Stay>())
        #expect(stays.first { $0.h3IndexRes6 == "V" }?.category == .unclassified)
        let freedSacred = try #require(stays.first { $0.h3IndexRes6 == "S" })
        #expect(freedSacred.category == .unclassified)
        #expect(!freedSacred.userOverridden,
                "back in pipeline custody — the flag came from the withdrawn teaching")
        #expect(stays.first { $0.h3IndexRes6 == "D" }?.category == .home)
        #expect(try ctx.fetch(FetchDescriptor<HomeAreaOverride>()).isEmpty)
        // Idempotent: removing a vanished row reports false, changes nothing.
        #expect(await classifier.removeOverride(id: override.id) == false)
    }

    // MARK: - Dissolve soft-delete queue

    @Test("a dissolve parks a full restoration record — healing never deletes irrecoverably")
    func dissolveParksRestorableRecord() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let home = makeHomeRow(in: ctx)
        let trip = makeVillageTrip(in: ctx, startDay: 0)
        trip.aiGeneratedTitle = "Village Weekend"
        let tripID = trip.id
        let stayID = try #require(trip.stays?.first?.id)
        addIncludeOverride(in: ctx, homeID: home.id)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        #expect((await classifier.healHomeAreaCorrections(
            pinnedTripIDs: [])).moved == 1)

        let parked = await classifier.drainParkedDissolvedTrips()
        let record = try #require(parked.first)
        #expect(parked.count == 1)
        #expect(record.id == tripID)
        #expect(record.displayName == "Village Weekend")
        #expect(record.stays.map(\.id) == [stayID])
        #expect(record.stays.first?.categoryRaw == StayCategory.destination.rawValue)
        // Drain empties — a second heal pass can't re-park stale records.
        #expect(await classifier.drainParkedDissolvedTrips().isEmpty)
    }

    @Test("restore re-mints the trip under its original id and protects its stays with user overrides")
    func restoreRecreatesTripUnderOriginalID() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let home = makeHomeRow(in: ctx)
        let trip = makeVillageTrip(in: ctx, startDay: 0)
        trip.aiGeneratedTitle = "Village Weekend"
        let tripID = trip.id
        let localizedWinnerID = try #require(UUID(
            uuidString: "00000000-0000-0000-0000-000000000001"))
        let localizedLargerTieID = try #require(UUID(
            uuidString: "00000000-0000-0000-0000-000000000002"))
        ctx.insert(TripTitleVariant(
            id: UUID(), languageTag: "el", title: "Παλιά γενιά",
            sourceTitle: "Village Weekend", generationVersion: 1,
            updatedAt: date(day: 10), trip: trip))
        ctx.insert(TripTitleVariant(
            id: localizedLargerTieID, languageTag: "el", title: "Μεγαλύτερο UUID",
            sourceTitle: "Village Weekend", generationVersion: 2,
            updatedAt: date(day: 5), trip: trip))
        ctx.insert(TripTitleVariant(
            id: localizedWinnerID, languageTag: "el", title: "Ω χαμένος",
            sourceTitle: "Village Weekend", generationVersion: 2,
            updatedAt: date(day: 5), trip: trip))
        ctx.insert(TripTitleVariant(
            id: localizedWinnerID, languageTag: "el",
            title: "Σαββατοκύριακο στο χωριό",
            sourceTitle: "Village Weekend", generationVersion: 2,
            updatedAt: date(day: 5), trip: trip))
        ctx.insert(TripTitleVariant(
            id: UUID(), languageTag: "fr", title: "Titre périmé",
            sourceTitle: "Old Canonical", generationVersion: 99,
            updatedAt: date(day: 99), trip: trip))
        addIncludeOverride(in: ctx, homeID: home.id)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        #expect((await classifier.healHomeAreaCorrections(
            pinnedTripIDs: [])).moved == 1)
        let record = try #require(await classifier.drainParkedDissolvedTrips().first)
        #expect(record.localizedTitles?.count == 1)
        #expect(record.localizedTitles?.first?.id == localizedWinnerID)

        #expect(await classifier.restoreDissolvedTrip(record, markStaysSacred: true) == .restored)
        let restored = try #require(try ctx.fetch(FetchDescriptor<Trip>()).first)
        #expect(restored.id == tripID, "favorites/photo choices keyed on the id come back")
        #expect(restored.isComplete)
        let stay = try #require(try ctx.fetch(FetchDescriptor<Stay>()).first)
        #expect(stay.category == .destination)
        #expect(stay.trip?.id == tripID)
        #expect(stay.userOverridden, "manual restore = the user saying this WAS a trip")
        let restoredTitles = try ctx.fetch(FetchDescriptor<TripTitleVariant>())
        #expect(restoredTitles.count == 1)
        #expect(restoredTitles.first?.id == localizedWinnerID)
        #expect(restoredTitles.first?.trip?.id == tripID)
        // Sacred stays now guard the trip from every future heal.
        #expect((await classifier.healHomeAreaCorrections(
            pinnedTripIDs: [])).moved == 0)
        // Double-restore refuses (the row exists).
        #expect(await classifier.restoreDissolvedTrip(record, markStaysSacred: true) == .alreadyExists)
    }

    @Test("dissolve capture, queue display and restore skip an incomplete-list translation")
    func dissolvedTitlesCarryOnlyUsableTranslations() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let home = makeHomeRow(in: ctx)
        let trip = makeVillageTrip(in: ctx, startDay: 0)
        trip.aiGeneratedTitle = "Village Weekend"
        let validID = try #require(UUID(
            uuidString: "00000000-0000-0000-0000-000000000002"))
        ctx.insert(TripTitleVariant(
            id: validID, languageTag: "el", title: "Χωριό και νησί",
            sourceTitle: "Village Weekend", generationVersion: 1,
            updatedAt: date(day: 1), trip: trip))
        // Newer, higher generation and a smaller UUID: it wins every metadata
        // tiebreak, but an incomplete list has no display authority.
        let malformedID = try #require(UUID(
            uuidString: "00000000-0000-0000-0000-000000000001"))
        ctx.insert(TripTitleVariant(
            id: malformedID,
            languageTag: "el", title: "Χωριό και",
            sourceTitle: "Village Weekend", generationVersion: 2,
            updatedAt: date(day: 9), trip: trip))
        addIncludeOverride(in: ctx, homeID: home.id)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        #expect((await classifier.healHomeAreaCorrections(
            pinnedTripIDs: [])).moved == 1)
        let record = try #require(await classifier.drainParkedDissolvedTrips().first)
        #expect(record.localizedTitles?.map(\.id) == [validID])
        #expect(record.displayName(languageTag: "el") == "Χωριό και νησί")

        #expect(await classifier.restoreDissolvedTrip(
            record, markStaysSacred: true) == .restored)
        let restoredTitles = try ModelContext(container).fetch(
            FetchDescriptor<TripTitleVariant>())
        #expect(restoredTitles.map(\.id) == [validID])
        let restored = try #require(try ModelContext(container).fetch(
            FetchDescriptor<Trip>()).first)
        #expect(restored.displayName(languageTag: "el") == "Χωριό και νησί")
    }

    @Test("a queued record's malformed newer translation never displays")
    func dissolvedRecordDisplayIgnoresMalformedTranslation() {
        let record = DissolvedTripRecord(
            id: UUID(), dissolvedAt: .now, displayName: "Old Snapshot",
            startDate: date(day: 0), endDate: date(day: 1), isComplete: true,
            destinationSummary: "Cephalonia", countryCodes: "GR",
            classifiedByAI: true, aiGeneratedTitle: "Island Escape",
            aiGeneratedSummary: nil, summarySourceRaw: nil,
            sourceRaw: DataSource.liveSLC.rawValue,
            customName: nil, userEdited: false, stays: [],
            localizedTitles: [
                .init(
                    id: UUID(), languageTag: "de", title: "Cephalonia und Lefkada",
                    sourceTitle: "Island Escape", generationVersion: 1,
                    updatedAt: Date(timeIntervalSinceReferenceDate: -23587199)),
                .init(
                    id: UUID(), languageTag: "de", title: "Cephalonia und",
                    sourceTitle: "Island Escape", generationVersion: 5,
                    updatedAt: Date(timeIntervalSinceReferenceDate: -23587198)),
            ])

        #expect(record.displayName(languageTag: "de") == "Cephalonia und Lefkada")
    }

    @Test("restore drops titles when a parked stay changed but keeps the stored narrative, which nothing can regenerate")
    func restoreRejectsStaleDerivedArtifactsAfterStayChange() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let home = makeHomeRow(in: context)
        let trip = makeVillageTrip(in: context, startDay: 0)
        trip.aiGeneratedTitle = "Village Weekend"
        trip.aiGeneratedSummary = "A quiet village weekend."
        trip.summarySourceRaw = SummarySource.foundationModels.rawValue
        context.insert(TripTitleVariant(
            languageTag: "de", title: "Dorfwochenende",
            sourceTitle: "Village Weekend", generationVersion: 1,
            updatedAt: .now, trip: trip))
        addIncludeOverride(in: context, homeID: home.id)
        try context.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        #expect((await classifier.healHomeAreaCorrections(
            pinnedTripIDs: [])).moved == 1)
        let record = try #require(await classifier
            .drainParkedDissolvedTrips().first)
        let parkedStay = try #require(try context.fetch(
            FetchDescriptor<Stay>()).first)
        parkedStay.locality = "Renamed Village"
        try context.save()

        #expect(await classifier.restoreDissolvedTrip(
            record, markStaysSacred: true) == .restored)
        let restored = try #require(try context.fetch(
            FetchDescriptor<Trip>()).first)
        #expect(restored.aiGeneratedTitle == nil)
        #expect(restored.titleSourceRevision == nil)
        #expect(restored.aiGeneratedSummary == "A quiet village weekend.")
        #expect(restored.summarySourceRaw == SummarySource.foundationModels.rawValue)
        #expect(restored.summaryGeneratedAt == record.endDate ?? record.startDate)
        #expect(try context.fetchCount(
            FetchDescriptor<TripTitleVariant>()) == 0)
    }

    @Test("restore drops titles when active Home prompt inputs changed")
    func restoreRejectsStaleTitlesAfterHomeChange() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let home = makeHomeRow(in: context)
        let trip = makeVillageTrip(in: context, startDay: 0)
        trip.aiGeneratedTitle = "Village Weekend"
        trip.aiGeneratedSummary = "A quiet village weekend."
        trip.summarySourceRaw = SummarySource.foundationModels.rawValue
        context.insert(TripTitleVariant(
            languageTag: "de", title: "Dorfwochenende",
            sourceTitle: "Village Weekend", generationVersion: 1,
            updatedAt: .now, trip: trip))
        addIncludeOverride(in: context, homeID: home.id)
        try context.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        #expect((await classifier.healHomeAreaCorrections(
            pinnedTripIDs: [])).moved == 1)
        let record = try #require(await classifier
            .drainParkedDissolvedTrips().first)
        // Locality is the Home field the title prompt reads; the label is not.
        home.locality = "New Home Locality"
        try context.save()

        #expect(await classifier.restoreDissolvedTrip(
            record, markStaysSacred: true) == .restored)
        let restored = try #require(try context.fetch(
            FetchDescriptor<Trip>()).first)
        #expect(restored.aiGeneratedTitle == nil)
        #expect(restored.titleSourceRevision == nil)
        #expect(restored.aiGeneratedSummary == "A quiet village weekend.",
                "Home inputs affect titles, not the trip narrative")
        #expect(try context.fetchCount(
            FetchDescriptor<TripTitleVariant>()) == 0)
    }

    /// The Home fingerprint that builds up to 49f7ab0 stored in recovery
    /// records for exactly the two Homes `parkLegacyHomeRecord` creates:
    /// SHA-256 of the id-sorted, key-sorted JSON rows
    /// `[{"country":"Greece","id":"00000000-0000-0000-0000-000000000001","isoCountryCode":"GR"},`
    /// `{"country":"Greece","id":"00000000-0000-0000-0000-000000000002","isoCountryCode":"GR","locality":"athens"}]`.
    private static let legacyTwoHomeTitleFingerprint =
        "d12397a816e7ef8d56d49303c8c450731ac788ca8c8ac103229a84a89cb8da87"

    private func parkLegacyHomeRecord() async throws -> (
        context: ModelContext, classifier: TripClassifier,
        athens: Home, record: DissolvedTripRecord
    ) {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let athens = makeHomeRow(in: context)
        athens.id = try #require(UUID(
            uuidString: "00000000-0000-0000-0000-000000000002"))
        athens.locality = "Athens"
        athens.country = "Greece"
        athens.isoCountryCode = "GR"
        let unnamed = makeHomeRow(in: context)
        unnamed.id = try #require(UUID(
            uuidString: "00000000-0000-0000-0000-000000000001"))
        unnamed.country = "Greece"
        unnamed.isoCountryCode = "GR"
        let trip = makeVillageTrip(in: context, startDay: 0)
        trip.aiGeneratedTitle = "Village Weekend"
        context.insert(TripTitleVariant(
            languageTag: "de", title: "Dorfwochenende",
            sourceTitle: "Village Weekend", generationVersion: 1,
            updatedAt: .now, trip: trip))
        addIncludeOverride(in: context, homeID: athens.id)
        try context.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        #expect((await classifier.healHomeAreaCorrections(
            pinnedTripIDs: [])).moved == 1)
        var record = try #require(await classifier
            .drainParkedDissolvedTrips().first)
        #expect(record.activeHomeTitleFingerprint
                != Self.legacyTwoHomeTitleFingerprint)
        // The same record as a pre-upgrade build parked it.
        record.activeHomeTitleFingerprint = Self.legacyTwoHomeTitleFingerprint
        return (context, classifier, athens, record)
    }

    @Test("restore keeps titles from a pre-upgrade record whose Homes are unchanged")
    func restoreKeepsTitlesFromLegacyHomeFingerprint() async throws {
        let (context, classifier, _, record) = try await parkLegacyHomeRecord()

        #expect(await classifier.restoreDissolvedTrip(
            record, markStaysSacred: true) == .restored)
        let restored = try #require(try context.fetch(
            FetchDescriptor<Trip>()).first)
        #expect(restored.aiGeneratedTitle == "Village Weekend")
        let variants = try context.fetch(FetchDescriptor<TripTitleVariant>())
        #expect(variants.map(\.title) == ["Dorfwochenende"])
        #expect(variants.first?.trip?.id == record.id)
    }

    @Test("restore drops titles from a pre-upgrade record whose Home changed")
    func restoreRejectsLegacyHomeFingerprintAfterHomeChange() async throws {
        let (context, classifier, athens, record) = try await parkLegacyHomeRecord()
        athens.locality = "Agios Dimitrios"
        try context.save()

        #expect(await classifier.restoreDissolvedTrip(
            record, markStaysSacred: true) == .restored)
        let restored = try #require(try context.fetch(
            FetchDescriptor<Trip>()).first)
        #expect(restored.aiGeneratedTitle == nil)
        #expect(try context.fetchCount(
            FetchDescriptor<TripTitleVariant>()) == 0)
    }

    @Test("partial dissolved restore waits for every recorded stay")
    func partialRestoreWaitsForMissingMembership() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let presentStay = Stay(
            startTime: date(day: 0.2), endTime: date(day: 0.4),
            centroidLatitude: Self.village.lat,
            centroidLongitude: Self.village.lon,
            h3IndexRes6: "partial-restore", pingCount: 2,
            distanceFromHomeKm: 17, pingIDs: [])
        presentStay.category = .home
        presentStay.locality = "Village"
        ctx.insert(presentStay)
        try ctx.save()

        let revision = UUID()
        let missingStayID = UUID()
        let record = DissolvedTripRecord(
            id: UUID(), dissolvedAt: .now, displayName: "Village & Island",
            startDate: date(day: 0), endDate: date(day: 1), isComplete: true,
            destinationSummary: "Village, Island", countryCodes: "GR",
            classifiedByAI: true, aiGeneratedTitle: "Village & Island",
            aiGeneratedSummary: "A narrative about both destinations.",
            summarySourceRaw: SummarySource.foundationModels.rawValue,
            sourceRaw: DataSource.liveSLC.rawValue,
            customName: "Our Journey", userEdited: true,
            stays: [
                .init(id: presentStay.id, categoryRaw: "destination", orderInTrip: 0),
                .init(id: missingStayID, categoryRaw: "destination", orderInTrip: 1),
            ],
            localizedTitles: [
                .init(
                    id: UUID(), languageTag: "de", title: "Dorf & Insel",
                    sourceTitle: "Village & Island", generationVersion: 1,
                    updatedAt: .now, sourceRevision: revision),
            ],
            titleSourceRevision: revision)

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.restoreDissolvedTrip(
            record, markStaysSacred: true) == .staysMissing)
        #expect(try ctx.fetch(FetchDescriptor<Trip>()).isEmpty)
        #expect(presentStay.trip == nil)
        #expect(presentStay.category == .home)
        #expect(!presentStay.userOverridden)
    }

    @Test("duplicate dissolved member IDs are not treated as exact membership")
    func duplicateMemberRestoreInvalidatesDerivedTitles() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let stay = Stay(
            startTime: date(day: 0), endTime: date(day: 0.5),
            centroidLatitude: Self.village.lat,
            centroidLongitude: Self.village.lon,
            h3IndexRes6: "duplicate-restore", pingCount: 2,
            distanceFromHomeKm: 17, pingIDs: [])
        stay.category = .home
        stay.locality = "Village"
        context.insert(stay)
        try context.save()

        let record = DissolvedTripRecord(
            id: UUID(), dissolvedAt: .now, displayName: "Duplicated",
            startDate: date(day: 0), endDate: date(day: 1), isComplete: true,
            destinationSummary: "Village", countryCodes: "GR",
            classifiedByAI: true, aiGeneratedTitle: "Village Escape",
            aiGeneratedSummary: "Full snapshot", summarySourceRaw: nil,
            sourceRaw: DataSource.liveSLC.rawValue,
            customName: nil, userEdited: false,
            stays: [
                .init(id: stay.id, categoryRaw: "destination", orderInTrip: 0),
                .init(id: stay.id, categoryRaw: "destination", orderInTrip: 1),
            ])

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.restoreDissolvedTrip(
            record, markStaysSacred: true) == .staysAmbiguous)
        #expect(try ModelContext(container).fetch(
            FetchDescriptor<Trip>()).isEmpty)
        #expect(stay.trip == nil)
        #expect(stay.category == .home)
    }

    @Test("partially claimed membership remains untouched and retryable")
    func partialClaimPreventsRestore() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let first = Stay(
            startTime: date(day: 0), endTime: date(day: 0.25),
            centroidLatitude: Self.village.lat,
            centroidLongitude: Self.village.lon,
            h3IndexRes6: "claim-first", pingCount: 2,
            distanceFromHomeKm: 17, pingIDs: [])
        let second = Stay(
            startTime: date(day: 0.5), endTime: date(day: 0.75),
            centroidLatitude: Self.village.lat,
            centroidLongitude: Self.village.lon,
            h3IndexRes6: "claim-second", pingCount: 2,
            distanceFromHomeKm: 17, pingIDs: [])
        first.category = .home
        second.category = .destination
        let newerTrip = Trip(startDate: second.startTime)
        context.insert(first)
        context.insert(second)
        context.insert(newerTrip)
        second.trip = newerTrip
        try context.save()
        let record = DissolvedTripRecord(
            id: UUID(), dissolvedAt: .now, displayName: "Two Stops",
            startDate: first.startTime, endDate: second.endTime,
            isComplete: true, destinationSummary: "Village",
            countryCodes: "GR", classifiedByAI: false,
            aiGeneratedTitle: nil, aiGeneratedSummary: nil,
            summarySourceRaw: nil, sourceRaw: DataSource.liveSLC.rawValue,
            customName: nil, userEdited: false,
            stays: [
                .init(id: first.id, categoryRaw: "destination", orderInTrip: 0),
                .init(id: second.id, categoryRaw: "destination", orderInTrip: 1),
            ])

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.restoreDissolvedTrip(
            record, markStaysSacred: true) == .staysClaimed)
        #expect(try context.fetch(FetchDescriptor<Trip>()).count == 1)
        #expect(first.trip == nil)
        #expect(first.category == .home)
        #expect(second.trip === newerTrip)
    }

    @Test("physical Stay twins make restore retry instead of guessing")
    func physicalStayTwinsPreventRestore() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let sharedID = UUID()
        for index in 0..<2 {
            let stay = Stay(
                startTime: date(day: Double(index)),
                endTime: date(day: Double(index) + 0.25),
                centroidLatitude: Self.village.lat,
                centroidLongitude: Self.village.lon,
                h3IndexRes6: "physical-twin-\(index)", pingCount: 2,
                distanceFromHomeKm: 17, pingIDs: [])
            stay.id = sharedID
            stay.category = .home
            context.insert(stay)
        }
        try context.save()
        let record = DissolvedTripRecord(
            id: UUID(), dissolvedAt: .now, displayName: "Ambiguous",
            startDate: date(day: 0), endDate: date(day: 1),
            isComplete: true, destinationSummary: "Village",
            countryCodes: "GR", classifiedByAI: false,
            aiGeneratedTitle: nil, aiGeneratedSummary: nil,
            summarySourceRaw: nil, sourceRaw: DataSource.liveSLC.rawValue,
            customName: nil, userEdited: false,
            stays: [.init(
                id: sharedID, categoryRaw: "destination", orderInTrip: 0)])

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.restoreDissolvedTrip(
            record, markStaysSacred: true) == .staysAmbiguous)
        #expect(try context.fetch(FetchDescriptor<Trip>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Stay>()).allSatisfy {
            $0.trip == nil && $0.category == .home
        })
    }

    @Test("a restore save failure rolls back and remains retryable")
    func restoreSaveFailureDoesNotLoseQueueRecovery() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let stay = Stay(
            startTime: date(day: 0), endTime: date(day: 0.5),
            centroidLatitude: Self.village.lat,
            centroidLongitude: Self.village.lon,
            h3IndexRes6: "save-failure", pingCount: 2,
            distanceFromHomeKm: 17, pingIDs: [])
        stay.category = .home
        context.insert(stay)
        try context.save()
        let record = DissolvedTripRecord(
            id: UUID(), dissolvedAt: .now, displayName: "Retry Me",
            startDate: stay.startTime, endDate: stay.endTime, isComplete: true,
            destinationSummary: "Village", countryCodes: "GR",
            classifiedByAI: false, aiGeneratedTitle: nil,
            aiGeneratedSummary: nil, summarySourceRaw: nil,
            sourceRaw: DataSource.liveSLC.rawValue,
            customName: nil, userEdited: false,
            stays: [.init(
                id: stay.id, categoryRaw: "destination", orderInTrip: 0)])

        let classifier = TripClassifier(modelContainer: container)
        await classifier.failNextDissolvedRestoreSave()
        #expect(await classifier.restoreDissolvedTrip(
            record, markStaysSacred: true) == .saveFailed)

        let verify = ModelContext(container)
        #expect(try verify.fetch(FetchDescriptor<Trip>()).isEmpty)
        let survivingStay = try #require(try verify.fetch(
            FetchDescriptor<Stay>()).first)
        #expect(survivingStay.trip == nil)
        #expect(survivingStay.category == .home)
    }

    @Test("restore identity read failures never mint a duplicate or consume recovery")
    func restoreIdentityReadFailureFailsClosed() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let stay = Stay(
            startTime: date(day: 0), endTime: date(day: 0.5),
            centroidLatitude: Self.village.lat,
            centroidLongitude: Self.village.lon,
            h3IndexRes6: "identity-read-failure", pingCount: 2,
            distanceFromHomeKm: 17, pingIDs: [])
        stay.category = .home
        context.insert(stay)
        try context.save()
        let record = DissolvedTripRecord(
            id: UUID(), dissolvedAt: .now, displayName: "Retry Me",
            startDate: stay.startTime, endDate: stay.endTime, isComplete: true,
            destinationSummary: "Village", countryCodes: "GR",
            classifiedByAI: false, aiGeneratedTitle: nil,
            aiGeneratedSummary: nil, summarySourceRaw: nil,
            sourceRaw: DataSource.liveSLC.rawValue,
            customName: nil, userEdited: false,
            stays: [.init(
                id: stay.id, categoryRaw: "destination", orderInTrip: 0)])

        let classifier = TripClassifier(modelContainer: container)
        await classifier.failDissolvedRestoreFetchCallForTesting(1)
        #expect(await classifier.restoreDissolvedTrip(
            record, markStaysSacred: true) == .saveFailed)
        await classifier.failDissolvedRestoreFetchCallForTesting(2)
        #expect(await classifier.restoreDissolvedTrip(
            record, markStaysSacred: true) == .saveFailed)

        let verification = ModelContext(container)
        #expect(try verification.fetch(FetchDescriptor<Trip>()).isEmpty)
        let survivingStay = try #require(try verification.fetch(
            FetchDescriptor<Stay>()).first)
        #expect(survivingStay.trip == nil)
        #expect(survivingStay.category == .home)
    }

    @Test("rescue restores exactly the parked trips a late-arriving pin guards, without sacred stamps")
    func rescueRestoresOnlyGuardedRecords() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let home = makeHomeRow(in: ctx)
        let pinnedID = makeVillageTrip(in: ctx, startDay: 0).id
        let unpinnedID = makeVillageTrip(in: ctx, startDay: 10).id
        addIncludeOverride(in: ctx, homeID: home.id)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        #expect((await classifier.healHomeAreaCorrections(
            pinnedTripIDs: [])).moved == 2)
        let parked = await classifier.drainParkedDissolvedTrips()
        #expect(parked.count == 2)

        // The pin lands AFTER the dissolve — the KVS race this queue closes.
        let outcome = await classifier.rescueDissolvedTrips(
            parked, pinnedTripIDs: [pinnedID])
        #expect(outcome.restored == [pinnedID])
        #expect(outcome.prunable.isEmpty)
        let trips = try ctx.fetch(FetchDescriptor<Trip>())
        #expect(trips.map(\.id) == [pinnedID])
        #expect(trips.first?.stays?.allSatisfy { !$0.userOverridden } == true,
                "the pin is the guard — auto-rescue never stamps sacred")
        _ = unpinnedID
    }

    @Test("rescue never mints a parked trip again over a stay the user set since: its record stays queued and Restore still brings it back")
    func rescueKeepsUserSetStay() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let home = makeHomeRow(in: ctx)
        let parkedID = makeVillageTrip(in: ctx, startDay: 0).id
        addIncludeOverride(in: ctx, homeID: home.id)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        #expect((await classifier.healHomeAreaCorrections(
            pinnedTripIDs: [])).moved == 1)
        let record = try #require(await classifier.drainParkedDissolvedTrips().first)
        #expect(record.id == parkedID)

        // Its stay joins a later trip (a regroup, stood in for here), which the
        // user then says was not a trip.
        let edit = ModelContext(container)
        let stay = try #require(try edit.fetch(FetchDescriptor<Stay>()).first)
        let later = Trip(startDate: stay.startTime)
        later.endDate = stay.endTime
        later.isComplete = true
        edit.insert(later)
        stay.category = .destination
        stay.userOverridden = false
        stay.trip = later
        stay.orderInTrip = 0
        try edit.save()
        let laterID = later.id
        #expect(await classifier.demoteSeededTrip(laterID).isDemoted)
        let demotedRecords = await classifier.drainParkedDissolvedTrips()
        let queue = [record] + demotedRecords
        // Only now does the user's own hide on the parked trip sync in.
        let sync = ModelContext(container)
        sync.insert(HiddenPhoto(localIdentifier: "late-hide", tripID: parkedID))
        try sync.save()

        let outcome = await classifier.rescueDissolvedTrips(queue, pinnedTripIDs: [])
        #expect(outcome.restored.isEmpty)
        #expect(outcome.prunable.isEmpty, "the record stays queued")
        let after = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>()).first)
        #expect(after.category == .home)
        #expect(after.userOverridden)
        #expect(after.trip == nil)
        #expect(await classifier.restoreDissolvedTrip(record, markStaysSacred: true) == .restored)
    }

    /// A row under a parked trip's id when a hide for it arrives.
    enum ParkedTripRow: CaseIterable, Sendable {
        /// An edited same-id twin healing kept beside the row it dissolved.
        case editedTwin
        /// The parked row synced back holding only its other stay.
        case syncedBack
    }

    @Test("rescue never hands a row back under a parked trip's id a stay the user set since: the stay stays home and the record stays queued",
          arguments: ParkedTripRow.allCases)
    func rescueKeepsUserSetStayFromReturnedRow(_ row: ParkedTripRow) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let home = makeHomeRow(in: ctx)
        let parked = makeVillageTrip(in: ctx, startDay: 0)
        let parkedID = parked.id
        switch row {
        case .editedTwin:
            makeVillageTrip(in: ctx, startDay: 0.25, userEdited: true).id = parkedID
        case .syncedBack:
            let start = date(day: 0.25)
            let second = Stay(
                startTime: start, endTime: start.addingTimeInterval(4 * 3600),
                centroidLatitude: Self.village.lat, centroidLongitude: Self.village.lon,
                h3IndexRes6: "V", pingCount: 2, distanceFromHomeKm: 17, pingIDs: [])
            second.category = .destination
            ctx.insert(second)
            second.trip = parked
        }
        addIncludeOverride(in: ctx, homeID: home.id)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        #expect((await classifier.healHomeAreaCorrections(
            pinnedTripIDs: [])).moved == 1)
        let record = try #require(await classifier.drainParkedDissolvedTrips().first)
        #expect(record.id == parkedID)
        #expect(record.stays.count == (row == .syncedBack ? 2 : 1))
        let movedID = try #require(record.stays.last?.id)

        // That stay joins a later trip (a regroup, stood in for here), which
        // the user then says was not a trip.
        let edit = ModelContext(container)
        let moved = try #require(try edit.fetch(FetchDescriptor<Stay>()).first { $0.id == movedID })
        let later = Trip(startDate: moved.startTime)
        later.endDate = moved.endTime
        later.isComplete = true
        edit.insert(later)
        moved.category = .destination
        moved.userOverridden = false
        moved.trip = later
        moved.orderInTrip = 0
        try edit.save()
        #expect(await classifier.demoteSeededTrip(later.id).isDemoted)

        // Only now does the parked row sync back with its other stay, and the
        // user's own hide on the parked trip sync in.
        let sync = ModelContext(container)
        if row == .syncedBack {
            let returned = Trip(startDate: date(day: 0))
            returned.id = parkedID
            returned.endDate = date(day: 0.5)
            returned.isComplete = true
            sync.insert(returned)
            let other = try #require(try sync.fetch(FetchDescriptor<Stay>())
                .first { $0.id == record.stays.first?.id })
            other.category = .destination
            other.trip = returned
            other.orderInTrip = 0
        }
        sync.insert(HiddenPhoto(localIdentifier: "late-hide", tripID: parkedID))
        try sync.save()

        let outcome = await classifier.rescueDissolvedTrips([record], pinnedTripIDs: [])
        #expect(outcome.restored.isEmpty)
        #expect(outcome.prunable.isEmpty, "the record stays queued")
        let after = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>())
            .first { $0.id == movedID })
        #expect(after.category == .home)
        #expect(after.userOverridden)
        #expect(after.trip == nil)
    }

    @Test("restore refuses when no member stay survives unclaimed")
    func restoreRefusesWhenStaysGone() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let home = makeHomeRow(in: ctx)
        makeVillageTrip(in: ctx, startDay: 0)
        addIncludeOverride(in: ctx, homeID: home.id)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        #expect((await classifier.healHomeAreaCorrections(
            pinnedTripIDs: [])).moved == 1)
        let record = try #require(await classifier.drainParkedDissolvedTrips().first)

        for stay in try ctx.fetch(FetchDescriptor<Stay>()) { ctx.delete(stay) }
        try ctx.save()
        #expect(await classifier.restoreDissolvedTrip(record, markStaysSacred: true) == .staysMissing,
                "missing (vs claimed) is the maybe-still-hydrating verdict — callers keep the record")
        #expect(try ctx.fetch(FetchDescriptor<Trip>()).isEmpty)
    }

    @Test("queue persistence round-trips, replaces re-dissolves, and removes cleanly")
    func queuePersistenceRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dissolve-queue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        func record(id: UUID, at day: Double, name: String) -> DissolvedTripRecord {
            DissolvedTripRecord(
                id: id, dissolvedAt: date(day: day), displayName: name,
                startDate: date(day: day - 1), endDate: date(day: day),
                isComplete: true,
                destinationSummary: name, countryCodes: "GR",
                classifiedByAI: false, aiGeneratedTitle: nil,
                aiGeneratedSummary: nil, summarySourceRaw: nil,
                sourceRaw: DataSource.liveSLC.rawValue,
                customName: nil, userEdited: false,
                stays: [.init(id: UUID(), categoryRaw: "destination", orderInTrip: 0)])
        }

        #expect(DissolvedTripQueue.load(from: dir).isEmpty)
        // Compatibility pin: the on-disk filename remains v1 and files made
        // before localized titles have no such key. Optional decoding must
        // preserve the whole record rather than treating the queue as corrupt.
        let legacy = record(id: UUID(), at: -1, name: "Legacy")
        let legacyData = try JSONEncoder().encode([legacy])
        #expect(!String(decoding: legacyData, as: UTF8.self)
            .contains("localizedTitles"))
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let queueURL = try #require(DissolvedTripQueue.fileURL(in: dir))
        try legacyData.write(to: queueURL)
        #expect(DissolvedTripQueue.load(from: dir) == [legacy])
        try DissolvedTripQueue.clear(in: dir)

        let a = record(id: UUID(), at: 0, name: "A")
        let b = record(id: UUID(), at: 1, name: "B")
        try DissolvedTripQueue.append([a, b], in: dir)
        #expect(DissolvedTripQueue.load(from: dir).map(\.displayName) == ["B", "A"],
                "newest dissolve first")

        // Re-dissolve of the same trip replaces its record, never duplicates.
        let a2 = record(id: a.id, at: 2, name: "A-again")
        try DissolvedTripQueue.append([a2], in: dir)
        let afterReplace = DissolvedTripQueue.load(from: dir)
        #expect(afterReplace.count == 2)
        #expect(afterReplace.first?.displayName == "A-again")

        try DissolvedTripQueue.remove(ids: [a.id, b.id], in: dir)
        #expect(DissolvedTripQueue.load(from: dir).isEmpty)

        // Appends arrive from classifier and maintenance actors. Their full
        // read/merge/write transaction must serialize, and recovery rows are
        // never evicted merely because more than 100 trips were dissolved.
        let concurrentRecords = (0..<105).map { index in
            record(
                id: UUID(), at: Double(index),
                name: "Concurrent-\(index)")
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for queued in concurrentRecords {
                group.addTask {
                    try DissolvedTripQueue.append([queued], in: dir)
                }
            }
            try await group.waitForAll()
        }
        #expect(DissolvedTripQueue.load(from: dir).count == 105)
    }

    @Test("a replacing queue record keeps the replaced record's photo rows once each")
    func queueReplacementKeepsPhotoAnnotations() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dissolve-queue-photos-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        typealias Ref = DissolvedTripRecord.PhotoAnnotationRef
        func ref(_ localIdentifier: String, pinned: Bool) -> Ref {
            Ref(id: UUID(), isPinned: pinned, localIdentifier: localIdentifier,
                cloudIdentifier: nil, date: date(day: 0))
        }
        func record(id: UUID, at day: Double, photos: [Ref]?) -> DissolvedTripRecord {
            var record = DissolvedTripRecord(
                id: id, dissolvedAt: date(day: day), displayName: "A",
                startDate: date(day: day - 1), endDate: date(day: day),
                isComplete: true, destinationSummary: "A", countryCodes: "GR",
                classifiedByAI: false, aiGeneratedTitle: nil,
                aiGeneratedSummary: nil, summarySourceRaw: nil,
                sourceRaw: DataSource.liveSLC.rawValue,
                customName: nil, userEdited: false,
                stays: [.init(id: UUID(), categoryRaw: "destination", orderInTrip: 0)])
            record.photoAnnotations = photos
            return record
        }

        let tripID = UUID()
        let hidden = ref("H1", pinned: false)
        let pinned = ref("P1", pinned: true)
        let other = record(id: UUID(), at: 0, photos: nil)
        try DissolvedTripQueue.append(
            [record(id: tripID, at: 1, photos: [hidden, pinned]), other], in: dir)

        // A newer snapshot of the same photo wins; the replaced record's
        // other rows are carried, never duplicated or dropped.
        let newerPinned = ref("P1", pinned: true)
        let newerHidden = ref("H2", pinned: false)
        let pinnedAsHidden = ref("P1", pinned: false)
        try DissolvedTripQueue.append(
            [record(id: tripID, at: 2, photos: [newerPinned, newerHidden, pinnedAsHidden])],
            in: dir)
        try DissolvedTripQueue.append([record(id: tripID, at: 3, photos: nil)], in: dir)

        let queued = DissolvedTripQueue.load(from: dir)
        #expect(queued.map(\.id) == [tripID, other.id])
        #expect(queued.first?.dissolvedAt == date(day: 3))
        #expect(queued.first?.photoAnnotations == [newerPinned, newerHidden, pinnedAsHidden, hidden])
        #expect(queued.last?.photoAnnotations == nil)
    }

    @Test("removing records of deleted stays keeps each record a remaining stay or trip still holds")
    func removingRecordsOfDeletedStaysKeepsHeldRecords() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dissolve-queue-deleted-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        func record(at day: Double, stays: [UUID]) -> DissolvedTripRecord {
            var record = DissolvedTripRecord(
                id: UUID(), dissolvedAt: date(day: day), displayName: "A",
                startDate: date(day: day - 1), endDate: date(day: day),
                isComplete: true, destinationSummary: "A", countryCodes: "GR",
                classifiedByAI: false, aiGeneratedTitle: nil,
                aiGeneratedSummary: nil, summarySourceRaw: nil,
                sourceRaw: DataSource.photoImport.rawValue,
                customName: nil, userEdited: false,
                stays: stays.enumerated().map {
                    DissolvedTripRecord.StayRef(
                        id: $0.element, categoryRaw: "destination", orderInTrip: $0.offset)
                })
            record.photoAnnotations = [.init(
                id: UUID(), isPinned: false, localIdentifier: "H-\(day)",
                cloudIdentifier: nil, date: date(day: day))]
            return record
        }

        let deleted = (0..<5).map { _ in UUID() }
        let kept = UUID()
        let twin = UUID()
        let absent = UUID()
        let allGone = record(at: 6, stays: [deleted[0], deleted[1]])
        let goneBesideAbsent = record(at: 5, stays: [deleted[2], absent])
        let partial = record(at: 4, stays: [deleted[3], kept])
        let twinned = record(at: 3, stays: [twin])
        let returned = record(at: 2, stays: [deleted[4]])
        let untouched = record(at: 1, stays: [absent])
        try DissolvedTripQueue.append(
            [allGone, goneBesideAbsent, partial, twinned, returned, untouched], in: dir)

        // Only a record with a deleted stay and no remaining stay or trip row
        // goes. An absent stay never counts as deleted; kept records are
        // unchanged, photo rows included.
        try DissolvedTripQueue.removeRecords(
            deletedStayIDs: Set(deleted + [twin]),
            remainingStayIDs: [kept, twin],
            remainingTripIDs: [returned.id],
            in: dir)
        #expect(DissolvedTripQueue.load(from: dir) == [partial, twinned, returned, untouched])

        // A queue left with no records is deleted outright.
        try DissolvedTripQueue.removeRecords(
            deletedStayIDs: [kept, twin, deleted[4], absent],
            remainingStayIDs: [], remainingTripIDs: [], in: dir)
        let queueURL = try #require(DissolvedTripQueue.fileURL(in: dir))
        #expect(!FileManager.default.fileExists(atPath: queueURL.path))

        // Unreadable bytes fail closed and stay untouched.
        let originalBytes = Data("not valid queue JSON".utf8)
        try originalBytes.write(to: queueURL)
        #expect(throws: (any Error).self) {
            try DissolvedTripQueue.removeRecords(
                deletedStayIDs: [kept], remainingStayIDs: [], remainingTripIDs: [], in: dir)
        }
        try DissolvedTripQueue.removeRecords(
            deletedStayIDs: [], remainingStayIDs: [], remainingTripIDs: [], in: dir)
        #expect(try Data(contentsOf: queueURL) == originalBytes)
    }

    @Test("queue append reports an unavailable persistence destination")
    func queueAppendFailureThrows() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dissolve-queue-blocked-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a directory".utf8).write(to: root)
        let record = DissolvedTripRecord(
            id: UUID(), dissolvedAt: .now, displayName: "Blocked",
            startDate: date(day: 0), endDate: date(day: 1),
            isComplete: true, destinationSummary: "Blocked",
            countryCodes: "GR", classifiedByAI: false,
            aiGeneratedTitle: nil, aiGeneratedSummary: nil,
            summarySourceRaw: nil, sourceRaw: DataSource.liveSLC.rawValue,
            customName: nil, userEdited: false, stays: [])

        #expect(throws: (any Error).self) {
            try DissolvedTripQueue.append([record], in: root)
        }
    }

    @Test("queue append never overwrites unreadable recovery bytes")
    func queueAppendFailsClosedOnCorruptExistingFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dissolve-queue-corrupt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let queueURL = try #require(DissolvedTripQueue.fileURL(in: dir))
        let originalBytes = Data("not valid queue JSON".utf8)
        try originalBytes.write(to: queueURL)
        let record = DissolvedTripRecord(
            id: UUID(), dissolvedAt: .now, displayName: "Must Not Replace",
            startDate: date(day: 0), endDate: date(day: 1),
            isComplete: true, destinationSummary: "Cephalonia",
            countryCodes: "GR", classifiedByAI: false,
            aiGeneratedTitle: nil, aiGeneratedSummary: nil,
            summarySourceRaw: nil, sourceRaw: DataSource.liveSLC.rawValue,
            customName: nil, userEdited: false, stays: [])

        #expect(throws: (any Error).self) {
            try DissolvedTripQueue.append([record], in: dir)
        }
        #expect(try Data(contentsOf: queueURL) == originalBytes)
    }

    @Test("queue removal never erases unreadable recovery bytes")
    func queueRemoveFailsClosedOnCorruptExistingFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dissolve-queue-corrupt-remove-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let queueURL = try #require(DissolvedTripQueue.fileURL(in: dir))
        let originalBytes = Data("not valid queue JSON".utf8)
        try originalBytes.write(to: queueURL)

        #expect(throws: (any Error).self) {
            try DissolvedTripQueue.remove(ids: [UUID()], in: dir)
        }
        #expect(try Data(contentsOf: queueURL) == originalBytes)
    }

    @Test("Calendar-title scrub removes generated recovery text and keeps safe names")
    func queueCalendarTitleScrubIsComplete() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dissolve-queue-calendar-scrub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let revision = UUID()
        let destinationRecord = DissolvedTripRecord(
            id: UUID(), dissolvedAt: .now,
            displayName: "Secret Conference",
            startDate: date(day: 0), endDate: date(day: 1),
            isComplete: true, destinationSummary: "Cephalonia",
            countryCodes: "GR", classifiedByAI: true,
            aiGeneratedTitle: "Secret Conference",
            aiGeneratedSummary: "A trip summary without calendar text.",
            summarySourceRaw: SummarySource.foundationModels.rawValue,
            sourceRaw: DataSource.liveSLC.rawValue,
            customName: nil, userEdited: false,
            stays: [.init(
                id: UUID(), categoryRaw: "destination", orderInTrip: 0)],
            localizedTitles: [.init(
                id: UUID(), languageTag: "de",
                title: "Geheime Konferenz",
                sourceTitle: "Secret Conference", generationVersion: 1,
                updatedAt: .now, sourceRevision: revision)],
            titleSourceRevision: revision,
            derivedSemanticDigest: "semantic",
            activeHomeTitleFingerprint: "home")
        let transitRecord = DissolvedTripRecord(
            id: UUID(), dissolvedAt: .now,
            displayName: "Private Event",
            startDate: date(day: 2), endDate: date(day: 3),
            isComplete: true, destinationSummary: "",
            countryCodes: "", classifiedByAI: true,
            aiGeneratedTitle: "Private Event", aiGeneratedSummary: nil,
            summarySourceRaw: nil, sourceRaw: DataSource.liveSLC.rawValue,
            customName: nil, userEdited: false,
            stays: [.init(
                id: UUID(), categoryRaw: "transit", orderInTrip: 0)])
        try DissolvedTripQueue.append(
            [destinationRecord, transitRecord], in: dir)

        try DissolvedTripQueue.scrubGeneratedTitles(in: dir)

        let scrubbed = DissolvedTripQueue.load(from: dir)
        #expect(scrubbed.count == 2)
        #expect(scrubbed.allSatisfy {
            $0.aiGeneratedTitle == nil
                && $0.titleSourceRevision == nil
                && $0.localizedTitles == nil
        })
        let destination = try #require(scrubbed.first {
            $0.id == destinationRecord.id
        })
        #expect(destination.displayName(languageTag: "en") == "Cephalonia")
        #expect(destination.aiGeneratedSummary
            == "A trip summary without calendar text.")
        let transit = try #require(scrubbed.first {
            $0.id == transitRecord.id
        })
        #expect(transit.displayName(languageTag: "en") == "Trip")
        let bytes = String(decoding: try Data(contentsOf: #require(
            DissolvedTripQueue.fileURL(in: dir))), as: UTF8.self)
        #expect(!bytes.contains("Secret Conference"))
        #expect(!bytes.contains("Geheime Konferenz"))
        #expect(!bytes.contains("Private Event"))
    }

    @Test("pending Calendar revocation strips new queue appends")
    func pendingCalendarRevocationStripsConcurrentAppend() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dissolve-queue-pending-revocation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let suiteName = "DissolvedTripQueueTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        DissolvedTripQueue.beginGeneratedTitleRevocation(
            defaults: defaults)
        let record = DissolvedTripRecord(
            id: UUID(), dissolvedAt: .now,
            displayName: "Private Occasion",
            startDate: date(day: 0), endDate: date(day: 1),
            isComplete: true, destinationSummary: "Cephalonia",
            countryCodes: "GR", classifiedByAI: true,
            aiGeneratedTitle: "Private Occasion",
            aiGeneratedSummary: nil, summarySourceRaw: nil,
            sourceRaw: DataSource.liveSLC.rawValue,
            customName: nil, userEdited: false,
            stays: [.init(
                id: UUID(), categoryRaw: "destination", orderInTrip: 0)],
            localizedTitles: [.init(
                id: UUID(), languageTag: "de",
                title: "Private Veranstaltung",
                sourceTitle: "Private Occasion", generationVersion: 1,
                updatedAt: .now)],
            titleSourceRevision: UUID())

        try DissolvedTripQueue.append(
            [record], in: dir, defaults: defaults)

        let stored = try #require(DissolvedTripQueue.load(from: dir).first)
        #expect(stored.aiGeneratedTitle == nil)
        #expect(stored.localizedTitles == nil)
        #expect(stored.titleSourceRevision == nil)
        #expect(stored.displayName == "Cephalonia")
        #expect(DissolvedTripQueue.generatedTitleRevocationIsPending(
            defaults: defaults))
        DissolvedTripQueue.finishGeneratedTitleRevocation(
            defaults: defaults)
        #expect(!DissolvedTripQueue.generatedTitleRevocationIsPending(
            defaults: defaults))
    }

    @Test("pending Calendar revocation prevents a preloaded restore from reviving titles")
    func pendingCalendarRevocationSuppressesRestoreTitles() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let home = makeHomeRow(in: context)
        let trip = makeVillageTrip(in: context, startDay: 0)
        trip.aiGeneratedTitle = "Private Occasion"
        let revision = UUID()
        trip.titleSourceRevision = revision
        context.insert(TripTitleVariant(
            languageTag: "de", title: "Private Veranstaltung",
            sourceTitle: "Private Occasion", sourceRevision: revision,
            generationVersion: 1, updatedAt: .now, trip: trip))
        addIncludeOverride(in: context, homeID: home.id)
        try context.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        #expect((await classifier.healHomeAreaCorrections(
            pinnedTripIDs: [])).moved == 1)
        let record = try #require(await classifier
            .drainParkedDissolvedTrips().first)
        await classifier.setGeneratedTitleRevocationPendingForTesting(true)
        #expect(await classifier.restoreDissolvedTrip(
            record, markStaysSacred: true) == .restored)

        let restored = try #require(try context.fetch(
            FetchDescriptor<Trip>()).first)
        #expect(restored.aiGeneratedTitle == nil)
        #expect(restored.titleSourceRevision == nil)
        #expect(try context.fetchCount(
            FetchDescriptor<TripTitleVariant>()) == 0)
    }

    @Test("dissolved title resolves a current-source language variant")
    func dissolvedTitleFollowsLanguage() throws {
        let revision = UUID()
        let older = Date(timeIntervalSinceReferenceDate: -23587199)
        let newer = Date(timeIntervalSinceReferenceDate: -23587198)
        let record = DissolvedTripRecord(
            id: UUID(), dissolvedAt: .now, displayName: "Old Greek Snapshot",
            startDate: date(day: 0), endDate: date(day: 1), isComplete: true,
            destinationSummary: "Cephalonia, Lefkada", countryCodes: "GR",
            classifiedByAI: true, aiGeneratedTitle: "Island Escape",
            aiGeneratedSummary: nil, summarySourceRaw: nil,
            sourceRaw: DataSource.liveSLC.rawValue,
            customName: nil, userEdited: false, stays: [],
            localizedTitles: [
                .init(
                    id: UUID(), languageTag: "DE_de", title: "Inselreise",
                    sourceTitle: "Island Escape", generationVersion: 1,
                    updatedAt: newer, sourceRevision: revision),
                .init(
                    id: UUID(), languageTag: "de", title: "Veraltet",
                    sourceTitle: "Old Title", generationVersion: 99,
                    updatedAt: older, sourceRevision: revision),
            ],
            titleSourceRevision: revision)

        #expect(record.displayName(languageTag: "de") == "Inselreise")
        #expect(record.displayName(languageTag: "fr") == "Island Escape")
    }

    @Test("legacy dissolved title resolves a matching nil-revision variant")
    func legacyDissolvedTitleFollowsLanguage() {
        let record = DissolvedTripRecord(
            id: UUID(), dissolvedAt: .now, displayName: "Old Snapshot",
            startDate: date(day: 0), endDate: date(day: 1), isComplete: true,
            destinationSummary: "Cephalonia", countryCodes: "GR",
            classifiedByAI: true, aiGeneratedTitle: "Island Escape",
            aiGeneratedSummary: nil, summarySourceRaw: nil,
            sourceRaw: DataSource.liveSLC.rawValue,
            customName: nil, userEdited: false, stays: [],
            localizedTitles: [.init(
                id: UUID(), languageTag: "de", title: "Inselreise",
                sourceTitle: "Island Escape", generationVersion: 1,
                updatedAt: .now, sourceRevision: nil)],
            titleSourceRevision: nil)

        #expect(record.displayName(languageTag: "de") == "Inselreise")
    }

    // MARK: - Fingerprint

    @Test("orbit fingerprint tolerates physical Stay UUID twins without changing evidence",
          arguments: [false, true])
    func fingerprintToleratesStayUUIDTwins(disagreeing: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        _ = makeHomeRow(in: context)
        let twinID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        for day in [0.0, 10, 20] {
            for (offset, hours, away) in [(0.0, 8.0, false), (11.0, 2.0, true), (18.0, 6.0, false)] {
                let start = date(day: day).addingTimeInterval(offset * 3600)
                let stay = Stay(
                    startTime: start, endTime: start.addingTimeInterval(hours * 3600),
                    centroidLatitude: away ? Self.village.lat : Self.home.lat,
                    centroidLongitude: away ? Self.village.lon : Self.home.lon,
                    h3IndexRes6: away ? "V" : "H", pingCount: 2,
                    distanceFromHomeKm: away ? 17 : 0, pingIDs: [])
                if day == 0 && away { stay.id = twinID }
                context.insert(stay)
            }
        }
        try context.save()
        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon, shape: Self.squareShape())
        let expected = try #require(await classifier.homeAreaFingerprint())
        #expect(expected.contains("|38.0000|23.9900|1.00|"), "fixture must admit a real orbit disc")

        let start = date(day: 0).addingTimeInterval(11 * 3600 + (disagreeing ? 60 : 0))
        let twin = Stay(
            startTime: start, endTime: start.addingTimeInterval((disagreeing ? 24 : 2) * 3600),
            centroidLatitude: Self.village.lat, centroidLongitude: Self.village.lon,
            h3IndexRes6: "V", pingCount: 2, distanceFromHomeKm: 17, pingIDs: [])
        twin.id = twinID
        context.insert(twin)
        try context.save()
        #expect(await classifier.homeAreaFingerprint() == expected)
        #expect(await classifier.homeAreaFingerprint() == expected)
        let rows = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        #expect(rows.count == 10)
        let twins = rows.filter { $0.id == twinID }
        #expect(twins.count == 2)
        #expect(Set(twins.map(\.persistentModelID)).count == 2)
    }

    @Test("the fingerprint moves on override add and remove, and is stable otherwise")
    func fingerprintTracksOverrides() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let home = makeHomeRow(in: ctx)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        let f0 = try #require(await classifier.homeAreaFingerprint())
        #expect(await classifier.homeAreaFingerprint() == f0)

        addIncludeOverride(in: ctx, homeID: home.id)
        try ctx.save()
        let f1 = try #require(await classifier.homeAreaFingerprint())
        #expect(f1 != f0)

        let row = try #require(try ctx.fetch(
            FetchDescriptor<HomeAreaOverride>()).first)
        ctx.delete(row)
        try ctx.save()
        #expect(await classifier.homeAreaFingerprint() == f0)
    }
}
