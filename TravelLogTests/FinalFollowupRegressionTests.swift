//
//  FinalFollowupRegressionTests.swift
//  TravelLogTests
//
//  Regression tests for the final review follow-ups (CF, P03, PIMP, SB2).
//

import EventKit
import Foundation
import SwiftData
import Testing
import os
@testable import TravelLog

// MARK: - SB2-4: entity string resolution never returns a partial match

@MainActor
@Suite("Trip entity string queries resolve whole-query matches only")
struct TripEntityStringQueryPartialTests {

    private func seed(_ name: String, year: Int, in context: ModelContext) -> Trip {
        var parts = DateComponents(year: year, month: 6, day: 10, hour: 12)
        parts.timeZone = TimeZone(identifier: "UTC")
        let trip = Trip(startDate: Calendar(identifier: .gregorian).date(from: parts)!)
        trip.endDate = trip.startDate.addingTimeInterval(4 * 86_400)
        trip.isComplete = true
        trip.customName = "\(name) Weekend"
        trip.destinationSummary = name
        context.insert(trip)
        return trip
    }

    @Test("a place with a year no trip has resolves nothing; the exact year resolves the trip")
    func partialNeverResolves() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let paris = seed("Paris", year: 2023, in: context)
        _ = seed("Rome", year: 2024, in: context)
        try context.save()

        #expect(try TripIntentSearch.entityMatches(query: "paris 2024", container: container, languageTag: "en").isEmpty)
        #expect(try TripIntentSearch.entityMatches(query: "paris 2023", container: container, languageTag: "en")
            .map(\.tripID) == [paris.id])
        let query = TripEntityQuery(container: container, isPersistentStore: true)
        #expect(try await query.entities(matching: "paris 2024").isEmpty)
    }
}

// MARK: - SB2-1: geocoder backfill paging never latches across a skipped window

private actor FollowupProbeCounter {
    private(set) var completions = 0
    func bump() { completions += 1 }
}

// In the chunking suite, which runs serialized: both set the one global probe.
extension GeocoderBackfillChunkingTests {

    @Test("deleting earlier rows between pages leaves the pass unlatched; a quiet rerun latches",
          .timeLimit(.minutes(2)))
    func deletionBetweenPagesWithholdsLatch() async throws {
        let base = Date(timeIntervalSinceReferenceDate: 722 * 86_400)
        // On land: the resolver answers nothing out at sea.
        let place = (lat: 44.3, lon: 11.9)
        _ = try #require(await GeocodeResolver.shared.resolve(latitude: place.lat, longitude: place.lon),
                         "bundled geocoder unavailable in this run")
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let total = AppDelegate.geocoderBackfillHexPage + 100
        for i in 0..<total {
            ctx.insert(HexVisit(
                h3Index: String(format: "gap-cell-%05d", i), firstVisited: base.addingTimeInterval(Double(i)),
                centerLatitude: place.lat, centerLongitude: place.lon))
        }
        try ctx.save()

        // After the first apply chunk, delete the 100 earliest rows: the second
        // page's offset then starts 100 rows further on, past the 32-row overlap.
        let gate = PipelineGate(forTesting: ())
        let fired = FollowupProbeCounter()
        let cutoff = base.addingTimeInterval(100)
        AppDelegate.geocoderBackfillInterChunkProbe = { @Sendable in
            guard await fired.completions == 0 else { return }
            await fired.bump()
            await gate.run(touching: [.hexVisit]) {
                let context = ModelContext(container)
                let early = (try? context.fetch(FetchDescriptor<HexVisit>(
                    predicate: #Predicate { $0.firstVisited < cutoff }))) ?? []
                for row in early { context.delete(row) }
                try? context.save()
            }
        }
        let gapped = await AppDelegate.backfillOfflineGeocoder(modelContainer: container, gate: gate)
        AppDelegate.geocoderBackfillInterChunkProbe = nil

        #expect(await fired.completions == 1)
        #expect(!gapped.saved, "rows between the two pages were never read, so the pass must not latch")

        let rerun = await AppDelegate.backfillOfflineGeocoder(modelContainer: container, gate: gate)
        #expect(rerun.saved)
        let hexes = try ModelContext(container).fetch(FetchDescriptor<HexVisit>())
        #expect(hexes.count == total - 100)
        #expect(hexes.allSatisfy { $0.isoCountryCode != nil })
    }
}

// MARK: - SB2-2: Calendar authority cannot promote local flight evidence

@MainActor
@Suite("Transit ignores calendar recording authority", .serialized)
struct TransitCalendarRevocationTests {

    private static let base = Date(timeIntervalSinceReferenceDate: 722 * 86_400)

    /// A short, slow leg that an overlapping booking must not promote.
    private func seedLeg(_ container: ModelContainer) throws -> UUID {
        let ctx = ModelContext(container)
        let predecessor = Stay(
            startTime: Self.base, endTime: Self.base.addingTimeInterval(3_600),
            centroidLatitude: 44.3, centroidLongitude: 12.9, h3IndexRes6: "", pingCount: 1,
            distanceFromHomeKm: 0, pingIDs: [])
        let target = Stay(
            startTime: Self.base.addingTimeInterval(4 * 3_600), endTime: Self.base.addingTimeInterval(8 * 3_600),
            centroidLatitude: 45.6, centroidLongitude: 12.9, h3IndexRes6: "", pingCount: 1,
            distanceFromHomeKm: 0, pingIDs: [])
        ctx.insert(predecessor)
        ctx.insert(target)
        try ctx.save()
        return target.id
    }

    private func transit(_ container: ModelContainer, _ id: UUID) throws -> String? {
        try #require(try ModelContext(container).fetch(
            FetchDescriptor<Stay>(predicate: #Predicate { $0.id == id })).first).transitFromPreviousRaw
    }

    @Test("calendar revocation during apply neither promotes nor blocks local classification",
          .timeLimit(.minutes(1)))
    func calendarRevocationDoesNotChangeLocalVerdict() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let target = try seedLeg(container)
        let inferer = TransitInferer(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        let enricher = CalendarEnricher(modelContainer: container)
        let legacyQueries = OSAllocatedUnfairLock(initialState: 0)
        let applied = OSAllocatedUnfairLock(initialState: 0)

        let revoked = await CalendarEnricher.TestScope.$authorizationStatus.withValue(.fullAccess) {
            await TransitInferer.TestScope.$corroborates.withValue({ _, _ in
                legacyQueries.withLock { $0 += 1 }
                return true
            }) {
                await TransitInferer.TestScope.$beforeApply.withValue({
                    // Reachable production seam after local evaluation. No
                    // Calendar query has vouched for a flight at this point.
                    applied.withLock { $0 += 1 }
                    await enricher.beginCalendarDataRevocation()
                }) {
                    await inferer.inferTransitBatchOutsideGate(gate: gate, publishing: false)
                }
            }
        }
        #expect(!revoked.failed)
        #expect(applied.withLock { $0 } == 1)
        #expect(legacyQueries.withLock { $0 } == 0)
        #expect(revoked.flights == 0)
        #expect(revoked.classified == 2)
        #expect(try transit(container, target) == TransitMode.unknown.rawValue)

        // Terminal local judgments are not left pending for calendar access.
        let fresh = await CalendarEnricher.TestScope.$authorizationStatus.withValue(.fullAccess) {
            await TransitInferer.TestScope.$corroborates.withValue({ _, _ in false }) {
                await inferer.inferTransitBatchOutsideGate(gate: gate, publishing: false)
            }
        }
        #expect(fresh.classified == 0)
        #expect(try transit(container, target) == TransitMode.unknown.rawValue)
    }
}

// MARK: - PIMP-003: phantom photo-only map cells are swept once hydration is past their grace

@MainActor
@Suite("A synced-store discard's kept map cells are swept after their grace", .serialized)
struct PhantomHexCellSweepTests {

    private static let base = Date(timeIntervalSinceReferenceDate: 722 * 86_400)
    private let grace = PhotoImportService.phantomHexCellGracePeriod

    private func withSuite<T>(_ body: (String, UserDefaults) async throws -> T) async rethrows -> T {
        let suite = "phantom-cells-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return try await body(suite, UserDefaults(suiteName: suite)!)
    }

    private func insertCell(_ context: ModelContext, _ cell: String, at date: Date) {
        let row = HexVisit(h3Index: cell, firstVisited: date, centerLatitude: 44.3, centerLongitude: 12.9)
        row.lastVisited = date
        context.insert(row)
    }

    private func insertPing(_ context: ModelContext, _ cell: String, at date: Date, source: DataSource) {
        context.insert(LocationPing(
            timestamp: date, latitude: 44.3, longitude: 12.9, horizontalAccuracy: 20,
            h3IndexRes6: cell, source: source))
    }

    private func pending(_ defaults: UserDefaults) -> [String: Double] {
        (defaults.dictionary(forKey: PhotoImportService.phantomHexCellsKey) as? [String: Double]) ?? [:]
    }

    @Test("a discard in a synced store queues the cell it kept; a local store deletes it and queues nothing",
          arguments: [false, true])
    func discardQueuesKeptCell(synced: Bool) async throws {
        try await withSuite { suite, defaults in
            let container = try TestSupport.makeInMemoryContainer()
            let context = ModelContext(container)
            insertPing(context, "photo-cell", at: Self.base, source: .photoImport)
            insertCell(context, "photo-cell", at: Self.base)
            try context.save()

            let service = PhotoImportService(modelContainer: container)
            try await PhotoImportService.HexAuthorityTestHook.$phantomCellSuiteName.withValue(suite) {
                try await PhotoImportService.HexAuthorityTestHook.$treatStoreAsSynced.withValue(synced) {
                    try await service.performDiscardTeardownForTesting()
                }
            }
            #expect(try ModelContext(container).fetchCount(FetchDescriptor<HexVisit>()) == (synced ? 1 : 0))
            #expect(Set(pending(defaults).keys) == (synced ? ["photo-cell"] : []))
        }
    }

    @Test("a queued cell with no fix left goes only after its grace and an import past it; a cell with a fix stays",
          .timeLimit(.minutes(1)))
    func sweepWaitsForGraceAndHydration() async throws {
        try await withSuite { suite, defaults in
            let container = try TestSupport.makeInMemoryContainer()
            let context = ModelContext(container)
            insertCell(context, "phantom-cell", at: Self.base)
            insertCell(context, "remote-cell", at: Self.base)
            // Another device's live fix in the second cell has arrived.
            insertPing(context, "remote-cell", at: Self.base, source: .liveSLC)
            try context.save()

            defaults.set(true, forKey: AppDelegate.iCloudSyncEnabledKey)
            let gate = PipelineGate(forTesting: ())
            func sweep(at now: Date) async -> Bool {
                await PhotoImportService.HexAuthorityTestHook.$phantomCellSuiteName.withValue(suite) {
                    await PhotoImportService.sweepPhantomHexCells(modelContainer: container, gate: gate, now: now)
                }
            }
            func cells() throws -> Set<String> {
                Set(try ModelContext(container).fetch(FetchDescriptor<HexVisit>()).map(\.h3Index))
            }
            PhotoImportService.HexAuthorityTestHook.$phantomCellSuiteName.withValue(suite) {
                PhotoImportService.recordPhantomHexCells(["phantom-cell", "remote-cell"], at: Self.base)
            }

            // Inside the grace nothing is judged.
            #expect(await sweep(at: Self.base.addingTimeInterval(grace / 2)))
            #expect(try cells() == ["phantom-cell", "remote-cell"])

            // Past the grace, but the last completed import is not: still hydrating.
            defaults.set(Self.base.addingTimeInterval(grace - 60), forKey: AppDelegate.lastSuccessfulCloudImportAtKey)
            #expect(await sweep(at: Self.base.addingTimeInterval(grace * 2)))
            #expect(try cells() == ["phantom-cell", "remote-cell"])
            #expect(pending(defaults).count == 2)

            // An import completed past the grace: the cell with no fix goes, the other stays.
            defaults.set(Self.base.addingTimeInterval(grace + 60), forKey: AppDelegate.lastSuccessfulCloudImportAtKey)
            #expect(await sweep(at: Self.base.addingTimeInterval(grace * 2)))
            #expect(try cells() == ["remote-cell"])
            #expect(pending(defaults).isEmpty)
        }
    }
}

// MARK: - P03-3: a larger journey holding the duplicate fixes is no carry counterpart

extension P03RegressionTests {

    /// A named day trip whose only fix duplicates one of a week-long trip's
    /// is not that journey: the week also holds a stop the day trip lacks.
    /// The day trip keeps its graph, name and photo choices.
    @Test("a duplicate trip is never carried onto a larger journey that merely contains its fixes")
    func supersetJourneyTakesNoCarry() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let week = photoTrip(context, from: at(0), to: at(168), fixAt: at(1))
        let elsewhere = insertPing(context, at: at(100), metersEast: 5_000, source: .liveSLC)
        insertStay(context, from: at(100), to: at(101), pings: [elsewhere], source: .liveSLC,
                   metersEast: 5_000, trip: week, order: 1)
        let day = photoTrip(context, from: at(0).addingTimeInterval(1), to: at(4),
                            fixAt: at(1).addingTimeInterval(20), name: "Harbour day")
        context.insert(HiddenPhoto(localIdentifier: "H1", tripID: day.id))
        try context.save()
        let defaults = freshDefaults()

        await PhotoImportPingDeduplicator.deduplicateAll(
            modelContainer: container, bypassSingleFlightForTesting: true, defaults: defaults)

        #expect(try trip(week.id, container)?.customName == nil)
        #expect(try trip(day.id, container)?.stays?.isEmpty == false)
        #expect(try ModelContext(container).fetch(FetchDescriptor<HiddenPhoto>()).map(\.tripID) == [day.id])
        #expect(TripDeduplicator.carriedWinners(defaults: defaults).isEmpty)
    }
}

// MARK: - CF-6: a second split keeps the first split's pending pieces

@MainActor
@Suite("Every split of a kept original forwards late hidden rows on its own cutoff", .serialized)
struct RepeatedSplitHiddenLineageTests {

    private static let base = Date(timeIntervalSinceReferenceDate: 820_000_000)

    private func at(_ hours: Double) -> Date { Self.base.addingTimeInterval(hours * 3_600) }

    @Test("a row hidden before the first split reaches both splits' pieces; one hidden between them only the second's")
    func secondSplitKeepsFirstSplitsSuccessors() async throws {
        let suite = "repeated-split-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let original = Trip(startDate: at(0))
        let firstPiece = Trip(startDate: at(10))
        let secondPiece = Trip(startDate: at(20))
        for trip in [original, firstPiece, secondPiece] { context.insert(trip) }
        try context.save()

        // A split into original + first piece, then the kept original split again.
        PhotoLineageStore.recordSplits([.init(
            parentID: original.id, successorIDs: [firstPiece.id], splitAt: at(100), settledRowIDs: [])],
            defaults: defaults)
        PhotoLineageStore.recordSplits([.init(
            parentID: original.id, successorIDs: [secondPiece.id], splitAt: at(200), settledRowIDs: [])],
            defaults: defaults)
        #expect(PhotoLineageStore.splitEvents(defaults: defaults)[original.id]?.count == 2)

        // Another device's hides of the original sync in after both splits.
        let early = HiddenPhoto(localIdentifier: "early-photo", tripID: original.id)
        early.hiddenAt = at(50)
        let between = HiddenPhoto(localIdentifier: "between-photo", tripID: original.id)
        between.hiddenAt = at(150)
        context.insert(early)
        context.insert(between)
        try context.save()

        #expect(await PhotoAnnotationDeduplicator.removeOrphans(
            modelContainer: container, now: at(300), defaults: defaults))

        let rows = try ModelContext(container).fetch(FetchDescriptor<HiddenPhoto>())
        func hidden(on trip: Trip) -> Set<String> {
            Set(rows.filter { $0.tripID == trip.id }.map(\.localIdentifier))
        }
        #expect(hidden(on: original) == ["early-photo", "between-photo"])
        #expect(hidden(on: firstPiece) == ["early-photo"])
        #expect(hidden(on: secondPiece) == ["early-photo", "between-photo"])
    }
}

// MARK: - Completed-trip regrouping fixtures (CF-1, CF-3, CF-4)

/// Whole-day fixture time from the reference date at fictional places; the
/// back half runs through its test seam with the lineage log isolated.
@MainActor
struct CompletedTripFixture {

    static let day: TimeInterval = 24 * 60 * 60

    func date(_ offset: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: offset * Self.day)
    }

    @discardableResult
    func stay(
        _ ctx: ModelContext, day startDay: Double, hours: Double = 6,
        _ category: StayCategory, hex: String = "fu"
    ) -> Stay {
        let start = date(startDay)
        let stay = Stay(
            startTime: start, endTime: start.addingTimeInterval(hours * 3600),
            centroidLatitude: 0, centroidLongitude: 0, h3IndexRes6: hex,
            pingCount: 2, distanceFromHomeKm: 0, pingIDs: [])
        stay.category = category
        ctx.insert(stay)
        return stay
    }

    @discardableResult
    func completedTrip(_ ctx: ModelContext, _ stays: [Stay]) -> Trip {
        let trip = Trip(startDate: stays[0].startTime)
        trip.endDate = stays[stays.count - 1].endTime
        trip.isComplete = true
        ctx.insert(trip)
        for (order, stay) in stays.enumerated() {
            stay.trip = trip
            stay.orderInTrip = order
        }
        return trip
    }

    func backHalf(_ classifier: TripClassifier, favourites: Set<UUID> = []) async throws {
        try await classifier.runIsolated { classifier in
            _ = try classifier.assembleClassificationResults(
                classified: 1, needsPublication: true, pinnedTripIDs: favourites)
        }
    }

    struct TripRow: Equatable {
        let id: UUID
        let stays: Set<UUID>
    }

    func trips(_ container: ModelContainer) throws -> [TripRow] {
        try ModelContext(container).fetch(FetchDescriptor<Trip>())
            .sorted { $0.startDate < $1.startDate }
            .map { TripRow(id: $0.id, stays: Set(($0.stays ?? []).map(\.id))) }
    }
}

// MARK: - CF-1: the idle check sees curation and membership changes

@MainActor
@Suite("The idle check reconsiders completed trips whose curation or members changed", IsolatedTitleDefaults())
struct IdleCheckCompletedTripTests {

    let fixture = CompletedTripFixture()

    @Test("a favourite left whole across a late night at home is reconsidered once it is unpinned, with no store change")
    func unpinnedFavouriteRearmsIdleCheck() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        fixture.stay(ctx, day: 0, .home)
        let first = fixture.stay(ctx, day: 1, .destination, hex: "fu-a")
        let second = fixture.stay(ctx, day: 5, .destination, hex: "fu-b")
        let trip = fixture.completedTrip(ctx, [first, second])
        fixture.stay(ctx, day: 6, .home)
        try ctx.save()
        let classifier = TripClassifier(modelContainer: container)
        try await fixture.backHalf(classifier, favourites: [trip.id])

        let late = ModelContext(container)
        fixture.stay(late, day: 3, .home)
        try late.save()
        try await fixture.backHalf(classifier, favourites: [trip.id])
        #expect(try fixture.trips(container) == [.init(id: trip.id, stays: [first.id, second.id])])

        #expect(await classifier.assemblyInvariantViolatedForTesting(pinnedTripIDs: [trip.id]) == false)
        #expect(await classifier.assemblyInvariantViolatedForTesting(pinnedTripIDs: []) == true,
                "an unpinned favourite has no store history, so only the curation comparison can see it")
        try await fixture.backHalf(classifier)
        #expect(try fixture.trips(container).count == 2)
    }

    @Test("a completed trip that syncs in with its stays across a home night re-arms the idle check, and the next pass splits it")
    func syncedCompletedTripRearmsIdleCheck() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        fixture.stay(ctx, day: 0, .home)
        let local = fixture.completedTrip(ctx, [fixture.stay(ctx, day: 1, .destination, hex: "fu-a")])
        fixture.stay(ctx, day: 2, .home)
        try ctx.save()
        let classifier = TripClassifier(modelContainer: container)
        try await fixture.backHalf(classifier)
        #expect(await classifier.assemblyInvariantViolatedForTesting() == false)

        // Another device's journey arrives whole: two stays, a night at home between.
        let synced = ModelContext(container)
        fixture.stay(synced, day: 9, .home)
        let x = fixture.stay(synced, day: 10, .destination, hex: "fu-x")
        fixture.stay(synced, day: 12, .home)
        let y = fixture.stay(synced, day: 14, .destination, hex: "fu-y")
        fixture.stay(synced, day: 15, .home)
        fixture.completedTrip(synced, [x, y])
        try synced.save()

        #expect(await classifier.assemblyInvariantViolatedForTesting() == true)
        try await fixture.backHalf(classifier)
        let all = try fixture.trips(container)
        #expect(all.count == 3)
        #expect(all.first?.id == local.id)
        #expect(Set(all.dropFirst().map(\.stays)) == [[x.id], [y.id]])
    }
}

// MARK: - CF-3: new away stays do not let one home photo split an assembled trip

@MainActor
@Suite("Regrouping a completed trip with new away stays splits it only at a retroactive boundary", IsolatedTitleDefaults())
struct RegroupedCompletedTripBoundaryTests {

    let fixture = CompletedTripFixture()

    @Test("one imported home photo beside a new away stay inside a completed trip leaves it whole; the new stay joins it")
    func homePhotoWithAwayStayLeavesTripWhole() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        fixture.stay(ctx, day: 0, .home)
        let first = fixture.stay(ctx, day: 1, .destination, hex: "fu-a")
        let last = fixture.stay(ctx, day: 5, .destination, hex: "fu-c")
        let trip = fixture.completedTrip(ctx, [first, last])
        fixture.stay(ctx, day: 6, .home)
        try ctx.save()
        let classifier = TripClassifier(modelContainer: container)
        try await fixture.backHalf(classifier)

        let late = ModelContext(container)
        let photo = fixture.stay(late, day: 2, hours: 0, .home)
        photo.source = .photoImport
        photo.pingCount = 1
        let away = fixture.stay(late, day: 3, .destination, hex: "fu-b")
        away.source = .photoImport
        try late.save()
        try await fixture.backHalf(classifier)

        #expect(try fixture.trips(container) == [.init(id: trip.id, stays: [first.id, away.id, last.id])])
    }

    enum Curation: CaseIterable, Sendable { case automatic, favourite, name, hiddenPhoto, pinnedPhoto, userSetStay }

    /// A completed trip with a real night at home arriving late inside it,
    /// together with a new away stay: the add-away path.
    private func curatedTripMeetsLateNightAndAwayStay(_ curation: Curation) async throws
        -> (container: ModelContainer, classifier: TripClassifier, trip: UUID, stays: [UUID], away: UUID) {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        fixture.stay(ctx, day: 0, .home)
        let first = fixture.stay(ctx, day: 1, .destination, hex: "fu-a")
        let last = fixture.stay(ctx, day: 5, .destination, hex: "fu-c")
        let trip = fixture.completedTrip(ctx, [first, last])
        fixture.stay(ctx, day: 6, .home)
        switch curation {
        case .automatic, .favourite: break
        case .name: trip.customName = "Coastal loop"
        case .hiddenPhoto: ctx.insert(HiddenPhoto(localIdentifier: "fu-hidden", tripID: trip.id))
        case .pinnedPhoto: ctx.insert(PinnedPhoto(localIdentifier: "fu-pinned", tripID: trip.id))
        case .userSetStay: first.userOverridden = true
        }
        try ctx.save()
        let favourites: Set<UUID> = curation == .favourite ? [trip.id] : []
        let classifier = TripClassifier(modelContainer: container)
        try await fixture.backHalf(classifier, favourites: favourites)

        let late = ModelContext(container)
        fixture.stay(late, day: 3, .home)
        let away = fixture.stay(late, day: 3.5, .destination, hex: "fu-b")
        try late.save()
        try await fixture.backHalf(classifier, favourites: favourites)
        return (container, classifier, trip.id, [first.id, last.id], away.id)
    }

    @Test("a curated trip stays whole across a late night at home that arrives with a new away stay, which joins it; an automatic one splits",
          arguments: Curation.allCases)
    func curatedTripStaysWholeOnTheAddAwayPath(curation: Curation) async throws {
        let (container, _, tripID, stays, away) = try await curatedTripMeetsLateNightAndAwayStay(curation)
        let trips = try ModelContext(container).fetch(FetchDescriptor<Trip>())
        if curation == .automatic {
            let rows = try fixture.trips(container)
            #expect(rows.count == 2)
            #expect(rows.first?.stays == [stays[0]])
            #expect(rows.last?.stays == [away, stays[1]])
            return
        }
        #expect(try fixture.trips(container) == [.init(id: tripID, stays: [stays[0], away, stays[1]])])
        let kept = try #require(trips.first)
        if curation == .name { #expect(kept.customName == "Coastal loop") }
        // Kept whole without the permanent edit mark, except where the user's
        // own stay marks it, as assembly always has.
        #expect(kept.userEdited == (curation == .userSetStay))
        #expect(try ModelContext(container).fetch(FetchDescriptor<HiddenPhoto>()).allSatisfy { $0.tripID == tripID })
        #expect(try ModelContext(container).fetch(FetchDescriptor<PinnedPhoto>()).allSatisfy { $0.tripID == tripID })
    }

    @Test("a favourite kept whole on the add-away path is reconsidered once it is unpinned, and the next pass splits it")
    func unpinnedFavouriteKeptOnAddAwayPathSplits() async throws {
        let (container, classifier, tripID, _, _) = try await curatedTripMeetsLateNightAndAwayStay(.favourite)
        #expect(try fixture.trips(container).count == 1)
        #expect(await classifier.assemblyInvariantViolatedForTesting(pinnedTripIDs: [tripID]) == false)
        #expect(await classifier.assemblyInvariantViolatedForTesting(pinnedTripIDs: []) == true)
        try await fixture.backHalf(classifier)
        #expect(try fixture.trips(container).count == 2)
    }
}

// MARK: - P03-1: the fallback's three-hour short stop is a classification input

extension P03RegressionTests {

    @Test("a transit stop imported fixes grow from two and a half to three hours is judged again")
    func stopGrownPastThreeHoursIsReclassified() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = insertTrip(context, from: at(0), to: at(14))
        let stop = insertStay(context, from: at(0), to: at(2.5), pings: [], source: .liveSLC,
                              category: .transit, trip: trip, order: 0)
        stop.durationMinutes = 150
        let base = insertStay(context, from: at(10), to: at(14), pings: [], source: .liveSLC,
                              metersEast: 50_000, trip: trip, order: 1)
        base.durationMinutes = 240
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        #expect(try await recorder.recordImportedPings([candidate(at(3))], source: .gpxImport) == 1)
        try await recorder.saveImportBatch()

        let grown = try #require(try stay(stop.id, container))
        #expect(grown.durationMinutes == 180)
        #expect(grown.category == .unclassified)
        #expect(grown.trip == nil)
        #expect(try stay(base.id, container)?.trip?.id == trip.id)
    }
}

// MARK: - P03-2: stays an import takes out of a completed trip still count as its own at the regroup

extension P03RegressionTests {

    /// A completed trip of three stops, with a night at home before its last
    /// stop. Imported fixes grow its first two stops, so they leave it to be
    /// judged again. Automatic, the regroup separates them from the last stop
    /// at the night at home, and the trip's id follows the two stops it held
    /// most of. With a hidden photo it is the user's whole journey: the
    /// regroup keeps its detached stops with it, under its id and its photo.
    @Test("the regroup after imported fixes move stops out of a completed trip keeps them as its own: a curated trip whole, an automatic one's id on its larger part",
          arguments: [false, true])
    func detachedStopsKeepTheirTripIdentity(hiddenPhoto: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = insertTrip(context, from: at(0), to: at(54))
        let first = insertStay(context, from: at(0), to: at(0).addingTimeInterval(300), pings: [],
                               source: .liveSLC, category: .transit, trip: trip, order: 0)
        first.durationMinutes = 5
        let second = insertStay(context, from: at(10), to: at(10).addingTimeInterval(300), pings: [],
                                source: .liveSLC, metersEast: 20_000, category: .transit, trip: trip, order: 1)
        second.durationMinutes = 5
        let night = insertStay(context, from: at(30), to: at(42), pings: [], source: .liveSLC,
                               metersEast: 40_000, category: .home)
        night.pingCount = 3
        night.durationMinutes = 720
        let last = insertStay(context, from: at(50), to: at(54), pings: [], source: .liveSLC,
                              metersEast: 60_000, trip: trip, order: 2)
        last.durationMinutes = 240
        if hiddenPhoto { context.insert(HiddenPhoto(localIdentifier: "p03-hidden", tripID: trip.id)) }
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        let fixes = (1...6).map { candidate(at(Double($0))) }
            + (11...16).map { candidate(at(Double($0)), metersEast: 20_000) }
        #expect(try await recorder.recordImportedPings(fixes, source: .gpxImport) == 12)
        try await recorder.saveImportBatch()
        #expect(try stay(first.id, container)?.trip == nil)
        #expect(try stay(second.id, container)?.trip == nil)

        // Classification judges the grown stops as places stayed at.
        let judged = ModelContext(container)
        for row in try judged.fetch(FetchDescriptor<Stay>()) where row.category == .unclassified {
            row.category = .destination
        }
        try judged.save()
        let classifier = TripClassifier(modelContainer: container)
        try await classifier.runIsolated { classifier in
            _ = try classifier.assembleClassificationResults(classified: 1, needsPublication: true)
        }

        let trips = try ModelContext(container).fetch(FetchDescriptor<Trip>())
        let kept = try #require(trips.first { $0.id == trip.id })
        let hidden = try ModelContext(container).fetch(FetchDescriptor<HiddenPhoto>())
        if hiddenPhoto {
            #expect(trips.count == 1)
            #expect(Set((kept.stays ?? []).map(\.id)) == [first.id, second.id, last.id])
            #expect(!kept.userEdited)
            #expect(hidden.map(\.tripID) == [trip.id])
        } else {
            #expect(Set((kept.stays ?? []).map(\.id)) == [first.id, second.id])
            let piece = try #require(trips.first { $0.id != trip.id })
            #expect(Set((piece.stays ?? []).map(\.id)) == [last.id])
            #expect(hidden.isEmpty)
        }
        #expect(PhotoLineageStore.detachedMembers(defaults: PhotoLineageStore.recorderDefaults).isEmpty)
    }
}

// MARK: - CF-4: a coverage edit's mark goes once nothing the user chose holds the trip

@MainActor
@Suite("A trip a coverage edit spared is automatic again once nothing the user chose holds it", IsolatedTitleDefaults())
struct SparedTripReleaseTests {

    let fixture = CompletedTripFixture()

    /// A completed trip marked edited only to spare it and logged so, as a
    /// Home or routine change leaves it.
    private func sparedTrip(_ container: ModelContainer, configure: (Trip) -> Void = { _ in })
        throws -> (trip: Trip, members: Set<UUID>) {
        let ctx = ModelContext(container)
        fixture.stay(ctx, day: 0, .home)
        let first = fixture.stay(ctx, day: 1, .destination, hex: "fu-a")
        let second = fixture.stay(ctx, day: 5, .destination, hex: "fu-b")
        fixture.stay(ctx, day: 6, .home)
        let trip = fixture.completedTrip(ctx, [first, second])
        trip.userEdited = true
        configure(trip)
        try ctx.save()
        let members: Set<UUID> = [first.id, second.id]
        TripClassifier.writeSparedTrips([trip.id: members], defaults: IsolatedTitleDefaults.current)
        return (trip, members)
    }

    /// A night at home inside the trip that arrives late.
    private func lateNightAtHome(_ container: ModelContainer) throws {
        let late = ModelContext(container)
        fixture.stay(late, day: 3, .home)
        try late.save()
    }

    private func editedTripCount(_ container: ModelContainer) throws -> Int {
        try ModelContext(container).fetch(FetchDescriptor<Trip>()).filter(\.userEdited).count
    }

    @Test("the favourite keeps the mark; once unpinned the idle check re-arms and the next pass releases and splits it")
    func unpinnedSparedTripIsReleased() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let (trip, members) = try sparedTrip(container)
        let classifier = TripClassifier(modelContainer: container)
        try await fixture.backHalf(classifier, favourites: [trip.id])
        try lateNightAtHome(container)
        try await fixture.backHalf(classifier, favourites: [trip.id])
        #expect(try fixture.trips(container) == [.init(id: trip.id, stays: members)])
        #expect(try editedTripCount(container) == 1)
        #expect(TripClassifier.sparedTrips(defaults: IsolatedTitleDefaults.current) == [trip.id: members])

        #expect(await classifier.assemblyInvariantViolatedForTesting(pinnedTripIDs: []) == true)
        try await fixture.backHalf(classifier)
        #expect(try fixture.trips(container).count == 2)
        #expect(try editedTripCount(container) == 0)
        #expect(TripClassifier.sparedTrips(defaults: IsolatedTitleDefaults.current).isEmpty)
    }

    @Test("a named spared trip keeps the mark and stays logged")
    func namedSparedTripKeepsMark() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let (trip, members) = try sparedTrip(container) { $0.customName = "Long weekend" }
        let classifier = TripClassifier(modelContainer: container)
        try await fixture.backHalf(classifier)
        try lateNightAtHome(container)
        try await fixture.backHalf(classifier)
        #expect(try fixture.trips(container) == [.init(id: trip.id, stays: members)])
        #expect(try editedTripCount(container) == 1)
        #expect(TripClassifier.sparedTrips(defaults: IsolatedTitleDefaults.current) == [trip.id: members])
    }

    @Test("a spared trip whose stays changed since the mark keeps it for good and leaves the log")
    func reshapedSparedTripKeepsMark() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let (trip, members) = try sparedTrip(container)
        // The log names a member the trip no longer holds, as after a user's split or merge.
        TripClassifier.writeSparedTrips([trip.id: members.union([UUID()])],
                                        defaults: IsolatedTitleDefaults.current)
        let classifier = TripClassifier(modelContainer: container)
        try await fixture.backHalf(classifier)
        try lateNightAtHome(container)
        try await fixture.backHalf(classifier)
        #expect(try fixture.trips(container) == [.init(id: trip.id, stays: members)])
        #expect(try editedTripCount(container) == 1)
        #expect(TripClassifier.sparedTrips(defaults: IsolatedTitleDefaults.current).isEmpty)
    }

    /// The accepted limitation: only the device whose log holds the trip can
    /// release it. Another device cannot tell the synced mark from the user's
    /// own edit, so it keeps it until the origin's release syncs.
    @Test("a device without the log keeps a synced mark; the origin's synced release lets the next pass split it")
    func receiverWithoutLogKeepsMarkUntilReleaseSyncs() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let (trip, members) = try sparedTrip(container)
        // The mark arrived through sync; the device-local log did not.
        TripClassifier.writeSparedTrips([:], defaults: IsolatedTitleDefaults.current)
        let classifier = TripClassifier(modelContainer: container)
        try await fixture.backHalf(classifier)
        try lateNightAtHome(container)
        try await fixture.backHalf(classifier)
        #expect(try fixture.trips(container) == [.init(id: trip.id, stays: members)])
        #expect(try editedTripCount(container) == 1)

        // The origin released the mark; its cleared flag syncs in.
        let synced = ModelContext(container)
        let row = try #require(try synced.fetch(FetchDescriptor<Trip>()).first { $0.id == trip.id })
        row.userEdited = false
        try synced.save()
        try await fixture.backHalf(classifier)
        #expect(try fixture.trips(container).count == 2)
        #expect(try editedTripCount(container) == 0)
    }
}
