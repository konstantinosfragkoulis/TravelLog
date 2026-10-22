//
//  TemporaryHomeReconciliationTests.swift
//  TravelLogTests
//
//  Declaring, editing, ending or removing a temporary home rewrites history
//  in one unit: stays at the base inside its dates become home, home stays
//  it no longer claims are freed, and the untouched trips around them are
//  reassembled on the new home gaps. Trips the user engaged with are kept.
//  These drive `applyTemporaryHomeChangeCore` on a throwaway store with
//  primed shapes, so Stage 2's model lane never runs.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

/// Collects the recovery records the classifier hands its sink, one per id as
/// the queue keeps them: a later record for an id replaces the earlier one (a
/// split hands its archive again once it committed).
private final class TemporaryHomeRecordBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [DissolvedTripRecord] = []

    func append(_ records: [DissolvedTripRecord]) {
        lock.lock()
        defer { lock.unlock() }
        for record in records {
            if let index = stored.firstIndex(where: { $0.id == record.id }) {
                stored[index] = record
            } else {
                stored.append(record)
            }
        }
    }

    var records: [DissolvedTripRecord] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private struct TemporaryHomeInjectedError: Error {}

@MainActor
private final class TemporaryHomeSettleLog {
    var events: [String] = []
}

/// A queued reconciliation and the suite it lives in, settled from the
/// entry point's `onSettled` as Settings settles it.
@MainActor
private final class TemporaryHomeDebt {
    let entry: CoverageReconciliationQueue.Entry
    let defaults: UserDefaults
    private(set) var settled = 0

    init(entry: CoverageReconciliationQueue.Entry, defaults: UserDefaults) {
        self.entry = entry
        self.defaults = defaults
    }

    func settle() {
        CoverageReconciliationQueue.complete(entry, defaults: defaults)
        settled += 1
    }
}

/// The favorites as the app holds them: main-actor state that can change
/// while a reconciliation waits its turn.
@MainActor
private final class TemporaryHomeFavorites {
    var ids: Set<UUID> = []
}

@MainActor
@Suite(IsolatedTitleDefaults())
struct TemporaryHomeReconciliationTests {

    private static let day: TimeInterval = 24 * 60 * 60
    private static let athens = (lat: 38.0, lon: 23.8)
    private static let brussels = (lat: 50.85, lon: 4.35)
    /// About 111 km north of the base.
    private static let ieper = (lat: 51.85, lon: 4.35)
    /// About 140 km east of the base.
    private static let bedburg = (lat: 50.85, lon: 6.35)
    /// Outside the base's urban centre.
    private static let airport = (lat: 50.90, lon: 4.48)
    /// About 260 km from the base and 2,100 km from the real home.
    private static let paris = (lat: 48.86, lon: 2.35)
    /// 12 km north of the real home's pin: outside its measured area (the
    /// 10 km square), inside its declared 25 km circle. No city boundary.
    private static let village = (lat: 38.108, lon: 23.8)
    /// 3 km north of the village: outside its 1 km area, inside the real home's circle.
    private static let nearVillage = (lat: 38.135, lon: 23.8)

    private func date(day offset: Double) -> Date { TemporaryHomeFixture.date(offset + 350) }

    /// `stampedBy` is the temporary home a home stay records as having made
    /// it home: an id-only stamp, as a legacy row carries it.
    private func makeStay(
        in ctx: ModelContext, at place: (lat: Double, lon: Double), startDay: Double,
        days: Double = 0.8, category: StayCategory, pingCount: Int = 2, stampedBy: UUID? = nil
    ) -> Stay {
        let start = date(day: startDay)
        return TemporaryHomeFixture.stay(
            ctx, place, from: start, to: start.addingTimeInterval(days * Self.day), category,
            hex: "S", pingCount: pingCount, idOnlyStamp: stampedBy)
    }

    @discardableResult
    private func makeTrip(in ctx: ModelContext, _ stays: [Stay], complete: Bool) -> Trip {
        TemporaryHomeFixture.trip(ctx, stays, complete: complete)
    }

    /// The real home in Athens, with a home stay before the semester.
    private func seedRealHome(in ctx: ModelContext) {
        TemporaryHomeFixture.realHome(ctx, "Athens", at: Self.athens)
            .startedAt = date(day: -1000)
        _ = makeStay(in: ctx, at: Self.athens, startDay: 0, category: .home)
    }

    private func insertSemester(
        in ctx: ModelContext, from: Double = 10, until: Double? = 100
    ) -> TemporaryHome {
        TemporaryHomeFixture.temporaryHome(
            ctx, "Semester", at: Self.brussels, from: from + 350, until: until.map { $0 + 350 }, zone: nil)
    }

    private func makeClassifier(_ container: ModelContainer) async -> TripClassifier {
        await TemporaryHomeFixture.classifier(container, squares: [(1, Self.athens), (2, Self.brussels)])
    }

    /// Remove Temporary Home as the save worker writes it: every row with the
    /// id keeps its content and carries the removal.
    private func markRemoved(_ id: UUID, in ctx: ModelContext, on day: Double = 120) throws {
        for row in try ctx.fetch(FetchDescriptor<TemporaryHome>()) where row.id == id {
            row.removedAt = date(day: day)
            row.modifiedAt = date(day: day)
        }
        try ctx.save()
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "TemporaryHomeReconciliationTests-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    /// A classifier that also knows the village, whose area is the 1 km fallback.
    private func makeClassifierWithVillage(_ container: ModelContainer) async -> TripClassifier {
        let classifier = await makeClassifier(container)
        await classifier.primeShapeForTesting(
            latitude: Self.village.lat, longitude: Self.village.lon,
            shape: .fallbackDisc(latitude: Self.village.lat, longitude: Self.village.lon))
        return classifier
    }

    /// What Settings runs after a temporary-home save, around the same core as
    /// the gated entry point.
    private func reconcile(
        _ classifier: TripClassifier, _ id: UUID, pinned: Set<UUID> = []
    ) async -> TripClassifier.TemporaryHomeReconciliationOutcome {
        await classifier.applyTemporaryHomeChangeCore(temporaryHomeID: id, pinnedTripIDs: pinned)
    }

    private struct StayState: Equatable {
        let category: String
        let tripID: UUID?
    }

    private struct StoreState: Equatable {
        let stays: [UUID: StayState]
        let tripIDs: Set<UUID>
    }

    /// Every stay's category and trip, and every trip id, as committed.
    private func storeState(_ container: ModelContainer) throws -> StoreState {
        let ctx = ModelContext(container)
        var stays: [UUID: StayState] = [:]
        for stay in try ctx.fetch(FetchDescriptor<Stay>()) {
            stays[stay.id] = StayState(category: stay.categoryRaw, tripID: stay.trip?.id)
        }
        let tripIDs = Set(try ctx.fetch(FetchDescriptor<Trip>()).map(\.id))
        return StoreState(stays: stays, tripIDs: tripIDs)
    }

    private func stayIDsByTrip(_ container: ModelContainer) throws -> [UUID: Set<UUID>] {
        var result: [UUID: Set<UUID>] = [:]
        for trip in try ModelContext(container).fetch(FetchDescriptor<Trip>()) {
            result[trip.id] = Set((trip.stays ?? []).map(\.id))
        }
        return result
    }

    private func stay(_ id: UUID, _ container: ModelContainer) throws -> Stay {
        try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>(
            predicate: #Predicate { $0.id == id })).first)
    }

    /// One completed trip covering a whole stay abroad: three long stretches at
    /// the base with two side trips between them, and the flight home.
    private struct SemesterTrip {
        let tripID: UUID
        let base: [UUID]
        let ieper: UUID
        let bedburg: UUID
        let station: UUID
        let flight: UUID
    }

    private func seedSemesterTrip(in ctx: ModelContext) -> SemesterTrip {
        let b1 = makeStay(in: ctx, at: Self.brussels, startDay: 10, days: 2.5, category: .destination)
        let ieper = makeStay(in: ctx, at: Self.ieper, startDay: 13, category: .destination)
        let b2 = makeStay(in: ctx, at: Self.brussels, startDay: 14, days: 6, category: .destination)
        let bedburg = makeStay(in: ctx, at: Self.bedburg, startDay: 21, days: 2, category: .destination)
        let station = makeStay(in: ctx, at: Self.airport, startDay: 23.2, days: 0.1, category: .transit)
        let b3 = makeStay(in: ctx, at: Self.brussels, startDay: 24, days: 6, category: .destination)
        let flight = makeStay(in: ctx, at: Self.airport, startDay: 30.5, days: 0.1, category: .transit)
        flight.isAirport = true
        _ = makeStay(in: ctx, at: Self.athens, startDay: 31, category: .home)
        let trip = makeTrip(in: ctx, [b1, ieper, b2, bedburg, station, b3, flight], complete: true)
        return SemesterTrip(
            tripID: trip.id, base: [b1.id, b2.id, b3.id], ieper: ieper.id,
            bedburg: bedburg.id, station: station.id, flight: flight.id)
    }

    /// A later completed trip that is nothing but the base and the flight home.
    private func seedBaseOnlyTrip(in ctx: ModelContext) -> (tripID: UUID, base: UUID, flight: UUID) {
        let base = makeStay(in: ctx, at: Self.brussels, startDay: 60, days: 3, category: .destination)
        let flight = makeStay(in: ctx, at: Self.airport, startDay: 63.5, days: 0.1, category: .transit)
        flight.isAirport = true
        _ = makeStay(in: ctx, at: Self.athens, startDay: 64, category: .home)
        let trip = makeTrip(in: ctx, [base, flight], complete: true)
        return (trip.id, base.id, flight.id)
    }

    // MARK: - Forward

    @Test("a temporary home declared late turns one long completed trip into its side trips: the base stays are home, the original trip id follows the larger side trip, and a lone flight stays tripless")
    func lateDeclarationSplitsCompletedTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        let semester = insertSemester(in: ctx)
        let fixture = seedSemesterTrip(in: ctx)
        try ctx.save()

        let classifier = await makeClassifier(container)
        let outcome = await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: semester.id, pinnedTripIDs: [])
        #expect(outcome == .committed(stamped: 3, freed: 0, rebuiltTrips: 1, protectedTrips: 0))

        for id in fixture.base {
            let base = try stay(id, container)
            #expect(base.category == .home)
            #expect(base.trip == nil)
        }
        let trips = try stayIDsByTrip(container)
        #expect(trips.count == 2)
        // Bedburg plus its station outweighs Ieper, so it keeps the id.
        #expect(trips[fixture.tripID] == [fixture.bedburg, fixture.station])
        #expect(Set(trips.values) == [[fixture.bedburg, fixture.station], [fixture.ieper]])
        for trip in try ModelContext(container).fetch(FetchDescriptor<Trip>()) {
            #expect(trip.isComplete)
        }
        // The Ieper trip spans exactly its one stay and closed on the return to the base.
        let ieperStay = try stay(fixture.ieper, container)
        let ieperTrip = try #require(ieperStay.trip)
        #expect(ieperTrip.startDate == ieperStay.startTime)
        #expect(ieperTrip.endDate == ieperStay.endTime)
        // It is measured from the base it left, about 111 km away.
        #expect(abs(ieperStay.distanceFromHomeKm - 111) < 3)

        let flight = try stay(fixture.flight, container)
        #expect(flight.category == .transit)
        #expect(flight.trip == nil)
    }

    @Test("an open trip that was only time at the base disappears and leaves no empty trip")
    func openTripAtTheBaseDisappears() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        let semester = insertSemester(in: ctx, until: nil)
        let first = makeStay(in: ctx, at: Self.brussels, startDay: 10, days: 5, category: .destination)
        let second = makeStay(in: ctx, at: Self.brussels, startDay: 16, days: 4, category: .destination)
        makeTrip(in: ctx, [first, second], complete: false)
        try ctx.save()

        let classifier = await makeClassifier(container)
        let outcome = await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: semester.id, pinnedTripIDs: [])
        #expect(outcome == .committed(stamped: 2, freed: 0, rebuiltTrips: 1, protectedTrips: 0))
        #expect(try ModelContext(container).fetch(FetchDescriptor<Trip>()).isEmpty)
        for id in [first.id, second.id] {
            let base = try stay(id, container)
            #expect(base.category == .home)
            #expect(base.trip == nil)
        }
    }

    @Test("a completed trip that was only the base is removed and parked for recovery with the categories it had")
    func fullyAbsorbedTripIsParkedWithOriginalCategories() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        let semester = insertSemester(in: ctx)
        let fixture = seedBaseOnlyTrip(in: ctx)
        try ctx.save()

        let classifier = await makeClassifier(container)
        let box = TemporaryHomeRecordBox()
        await classifier.setDissolvedRecordSink { box.append($0) }
        let outcome = await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: semester.id, pinnedTripIDs: [])
        #expect(outcome == .committed(stamped: 1, freed: 0, rebuiltTrips: 1, protectedTrips: 0))

        // The durable sink and the healing drain both hold the one record.
        let record = try #require(box.records.first)
        #expect(box.records.count == 1)
        #expect(await classifier.drainParkedDissolvedTrips().map(\.id) == [fixture.tripID])
        #expect(record.id == fixture.tripID)
        #expect(record.isComplete)
        #expect(record.stays.map(\.id) == [fixture.base, fixture.flight])
        #expect(record.stays.map(\.categoryRaw) == ["destination", "transit"])

        #expect(try ModelContext(container).fetch(FetchDescriptor<Trip>()).isEmpty)
        #expect(try stay(fixture.base, container).category == .home)
        let flight = try stay(fixture.flight, container)
        #expect(flight.category == .transit)
        #expect(flight.trip == nil)
    }

    // MARK: - Protection

    @Test("a trip the user engaged with that the temporary home covers is split whatever the engagement was: it is archived first with the categories it had, its id is retired and its side trip is a trip of its own",
          arguments: TripClassifier.TripInteraction.allCases)
    func engagedTripIsSplit(interaction: TripClassifier.TripInteraction) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        let semester = insertSemester(in: ctx)
        let base = makeStay(in: ctx, at: Self.brussels, startDay: 10, days: 2, category: .destination)
        let side = makeStay(in: ctx, at: Self.ieper, startDay: 13, category: .destination)
        _ = makeStay(in: ctx, at: Self.athens, startDay: 15, category: .home)
        let trip = makeTrip(in: ctx, [base, side], complete: true)
        // A tripless stay at the base, so the unit has work and runs assembly.
        let loose = makeStay(in: ctx, at: Self.brussels, startDay: 50, category: .destination)
        switch interaction {
        case .userEdited: trip.userEdited = true
        case .customName: trip.customName = "Erasmus"
        case .pinned: break
        case .hiddenPhoto: ctx.insert(HiddenPhoto(localIdentifier: "asset-1", tripID: trip.id))
        case .pinnedPhoto: ctx.insert(PinnedPhoto(localIdentifier: "asset-2", tripID: trip.id))
        // A stay the user set is never converted, so the setting is on the side trip.
        case .stayOverridden: side.userOverridden = true
        }
        try ctx.save()

        let classifier = await makeClassifier(container)
        let box = TemporaryHomeRecordBox()
        await classifier.setDissolvedRecordSink { box.append($0) }
        let outcome = await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: semester.id,
            pinnedTripIDs: interaction == .pinned ? [trip.id] : [])
        #expect(outcome == .committed(stamped: 2, freed: 0, rebuiltTrips: 1, protectedTrips: 0))

        let record = try #require(box.records.first)
        #expect(box.records.map(\.id) == [trip.id])
        #expect(record.splitByTemporaryHomeID == semester.id)
        #expect(record.stays.map(\.categoryRaw) == ["destination", "destination"])
        let trips = try stayIDsByTrip(container)
        #expect(trips[trip.id] == nil)
        #expect(Array(trips.values) == [[side.id]])
        let based = try stay(base.id, container)
        #expect(based.category == .home)
        #expect(based.trip == nil)
        #expect(!based.userOverridden)
        #expect(try stay(side.id, container).category == .destination)
        let stamped = try stay(loose.id, container)
        #expect(stamped.category == .home)
        #expect(stamped.trip == nil)
    }

    // MARK: - Visit backing

    @Test("a single-ping stay at the base is home but does not split the trips around it, unless a Visit backs it",
          arguments: [false, true])
    func singlePingBaseStaySplitsOnlyWithAVisit(visitBacked: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        let semester = insertSemester(in: ctx)
        let first = makeStay(in: ctx, at: Self.ieper, startDay: 10, category: .destination)
        let ping = makeStay(in: ctx, at: Self.brussels, startDay: 12, days: 1.0 / 24,
                            category: .destination, pingCount: 1)
        let second = makeStay(in: ctx, at: Self.bedburg, startDay: 13, category: .destination)
        _ = makeStay(in: ctx, at: Self.athens, startDay: 20, category: .home)
        let trip = makeTrip(in: ctx, [first, ping, second], complete: true)
        if visitBacked {
            ctx.insert(Visit(
                arrivalDate: ping.startTime, departureDate: ping.endTime,
                latitude: Self.brussels.lat, longitude: Self.brussels.lon,
                stayID: ping.id, isProcessed: true))
        }
        try ctx.save()

        // A classifier that has never run a pass: the unit reads Visit backing itself.
        let classifier = await makeClassifier(container)
        let outcome = await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: semester.id, pinnedTripIDs: [])
        #expect(outcome == .committed(stamped: 1, freed: 0, rebuiltTrips: 1, protectedTrips: 0))

        let stamped = try stay(ping.id, container)
        #expect(stamped.category == .home)
        #expect(stamped.trip == nil)
        let trips = try stayIDsByTrip(container)
        if visitBacked {
            #expect(Set(trips.values) == [[first.id], [second.id]])
            #expect(trips[trip.id] != nil)
        } else {
            #expect(trips == [trip.id: [first.id, second.id]])
        }
    }

    // MARK: - Reverse

    @Test("ending a temporary home earlier frees the home stays after the new end and keeps the earlier ones")
    func endingEarlierFreesLaterHomeStays() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        let semester = insertSemester(in: ctx)
        let early = makeStay(in: ctx, at: Self.brussels, startDay: 20, category: .home,
                             stampedBy: semester.id)
        let middle = makeStay(in: ctx, at: Self.brussels, startDay: 50, category: .home,
                              stampedBy: semester.id)
        let late = makeStay(in: ctx, at: Self.brussels, startDay: 90, category: .home,
                            stampedBy: semester.id)
        try ctx.save()
        semester.endedAt = date(day: 60)
        try ctx.save()

        let classifier = await makeClassifier(container)
        let outcome = await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: semester.id, pinnedTripIDs: [])
        #expect(outcome == .committed(stamped: 0, freed: 1, rebuiltTrips: 0, protectedTrips: 0))

        #expect(try stay(early.id, container).category == .home)
        #expect(try stay(middle.id, container).category == .home)
        let freed = try stay(late.id, container)
        #expect(freed.category == .unclassified)
        // Measured from the real home again, about 2,090 km away.
        #expect(freed.distanceFromHomeKm > 2000)
        // The real home's own stay is untouched.
        #expect(try storeState(container).stays.values.filter { $0.category == "home" }.count == 3)
    }

    @Test("removing a temporary home frees every home stay it claimed and leaves the real home's stays alone")
    func removalFreesEveryClaimedStay() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        let semester = insertSemester(in: ctx)
        let semesterID = semester.id
        let claimed = [20.0, 50, 90].map {
            makeStay(in: ctx, at: Self.brussels, startDay: $0, category: .home,
                     stampedBy: semesterID).id
        }
        try ctx.save()
        try markRemoved(semesterID, in: ctx)

        let classifier = await makeClassifier(container)
        let outcome = await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: semesterID, pinnedTripIDs: [])
        #expect(outcome == .committed(stamped: 0, freed: 3, rebuiltTrips: 0, protectedTrips: 0))
        for id in claimed {
            #expect(try stay(id, container).category == .unclassified)
        }
        #expect(try storeState(container).stays.values.filter { $0.category == "home" }.count == 1)
    }

    @Test("a temporary home far from the real home frees nothing there: a real-home stay outside the measured area but inside the home's declared circle stays home when the temporary home is added and when it is removed, also when it predates the real home, so does an older home stay no area claims, and the removal still frees the stay the temporary home made home")
    func realHomeStaysInsideTheDeclaredCircleAreLeftAlone() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        // 12 km north of the pin: outside the 10 km square, inside the 25 km circle.
        let outskirts = (lat: Self.athens.lat + 0.108, lon: Self.athens.lon)
        let legacy = makeStay(in: ctx, at: outskirts, startDay: 2, category: .home)
        let beforeTheHome = makeStay(in: ctx, at: outskirts, startDay: -2000, category: .home)
        // 40 km north: outside the circle too, so no area accounts for it.
        let unclaimed = makeStay(
            in: ctx, at: (lat: Self.athens.lat + 0.36, lon: Self.athens.lon),
            startDay: 4, category: .home)
        let base = makeStay(in: ctx, at: Self.brussels, startDay: 50, category: .destination)
        let semester = insertSemester(in: ctx)
        let semesterID = semester.id
        try ctx.save()

        let classifier = await makeClassifier(container)
        #expect(await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: semesterID, pinnedTripIDs: [])
            == .committed(stamped: 1, freed: 0, rebuiltTrips: 0, protectedTrips: 0))
        #expect(try stay(legacy.id, container).category == .home)
        #expect(try stay(beforeTheHome.id, container).category == .home)
        // No temporary home made it home (it records none), so a temporary
        // home's reconciliation has no say over it, wherever it lies.
        #expect(try stay(unclaimed.id, container).category == .home)
        #expect(try stay(base.id, container).category == .home)
        #expect(try stay(base.id, container).temporaryHomeID == semesterID)

        try markRemoved(semesterID, in: ctx)
        #expect(await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: semesterID, pinnedTripIDs: [])
            == .committed(stamped: 0, freed: 1, rebuiltTrips: 0, protectedTrips: 0))
        #expect(try stay(legacy.id, container).category == .home)
        #expect(try stay(beforeTheHome.id, container).category == .home)
        #expect(try stay(unclaimed.id, container).category == .home)
        #expect(try stay(base.id, container).category == .unclassified)
    }

    // MARK: - What the unit leaves tripless

    /// A completed trip that was two stretches at the base around a four-hour
    /// outing 13 km from it, measured from Athens as an earlier pass left it.
    private func seedTripWithANearBaseOuting(in ctx: ModelContext) -> (base: [UUID], outing: [UUID]) {
        let nearby = (lat: Self.brussels.lat + 0.121, lon: Self.brussels.lon)
        let first = makeStay(in: ctx, at: Self.brussels, startDay: 10, days: 2.5, category: .destination)
        let outing = [13.0, 13.1].map {
            makeStay(in: ctx, at: nearby, startDay: $0, days: 2.0 / 24, category: .destination)
        }
        let second = makeStay(in: ctx, at: Self.brussels, startDay: 14, days: 6, category: .destination)
        _ = makeStay(in: ctx, at: Self.athens, startDay: 31, category: .home)
        for stay in [first, second] + outing { stay.distanceFromHomeKm = 2_090 }
        makeTrip(in: ctx, [first] + outing + [second], complete: true)
        return ([first.id, second.id], outing.map(\.id))
    }

    @Test("an outing near the base that the rebuilt trip leaves tripless shows in Near-Home Activity with its distance from the base, not from the real home")
    func nearBaseOutingLeftTriplessIsMeasuredFromTheBase() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        let semester = insertSemester(in: ctx)
        let fixture = seedTripWithANearBaseOuting(in: ctx)
        try ctx.save()

        let classifier = await makeClassifier(container)
        #expect(await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: semester.id, pinnedTripIDs: [])
            == .committed(stamped: 2, freed: 0, rebuiltTrips: 1, protectedTrips: 0))

        // The outing is too close to the base to be a trip.
        #expect(try ModelContext(container).fetch(FetchDescriptor<Trip>()).isEmpty)
        for id in fixture.outing {
            let outing = try stay(id, container)
            #expect(outing.category == .destination)
            #expect(outing.trip == nil)
        }
        let groups = await classifier.suppressedGroups()
        #expect(groups.map(\.stayIDs) == [fixture.outing])
        let shown = try #require(groups.first?.maxDistanceKm)
        #expect(abs(shown - 13.5) < 1, "\(shown) km")
    }

    @Test("a reconciliation with nothing to change keeps the tripless outings the last assembly set aside excused, so the next pass does not rebuild for them")
    func runWithNothingToChangeKeepsSetAsideOutingsExcused() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        let semester = insertSemester(in: ctx)
        _ = seedTripWithANearBaseOuting(in: ctx)
        try ctx.save()

        let classifier = await makeClassifier(container)
        #expect(await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: semester.id, pinnedTripIDs: []).isSettled)
        // The unit's assembly set the outing aside and remembers it.
        #expect(await classifier.assemblyInvariantViolatedForTesting() == false)

        // A replay, as the queue's drain runs one.
        #expect(await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: semester.id, pinnedTripIDs: [])
            == .committed(stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 0))
        #expect(await classifier.assemblyInvariantViolatedForTesting() == false)
    }

    // MARK: - Same-id trip twins

    @Test("two trip rows that share one id leave at most one rebuilt trip with that id, whether they hold copies of the same stays or different stays",
          arguments: [true, false])
    func twinTripRowsHandTheirIDToOneRebuiltTrip(copies: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        let semester = insertSemester(in: ctx)
        func semesterStays() -> [Stay] {
            [makeStay(in: ctx, at: Self.brussels, startDay: 10, days: 2.5, category: .destination),
             makeStay(in: ctx, at: Self.ieper, startDay: 13, category: .destination),
             makeStay(in: ctx, at: Self.brussels, startDay: 14, days: 6, category: .destination),
             makeStay(in: ctx, at: Self.bedburg, startDay: 21, days: 2, category: .destination),
             makeStay(in: ctx, at: Self.airport, startDay: 23.2, days: 0.1, category: .transit),
             makeStay(in: ctx, at: Self.brussels, startDay: 24, days: 6, category: .destination)]
        }
        let original = semesterStays()
        _ = makeStay(in: ctx, at: Self.athens, startDay: 31, category: .home)
        let first: Trip
        let second: Trip
        if copies {
            // Two imports of one backup: each row owns its own copy of every stay.
            let duplicate = semesterStays()
            for (copy, source) in zip(duplicate, original) { copy.id = source.id }
            first = makeTrip(in: ctx, original, complete: true)
            second = makeTrip(in: ctx, duplicate, complete: true)
        } else {
            first = makeTrip(in: ctx, Array(original[0...2]), complete: true)
            second = makeTrip(in: ctx, Array(original[3...5]), complete: true)
        }
        second.id = first.id
        try ctx.save()
        let sharedID = first.id

        let classifier = await makeClassifier(container)
        #expect(await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: semester.id, pinnedTripIDs: [])
            == .committed(stamped: copies ? 6 : 3, freed: 0, rebuiltTrips: 2, protectedTrips: 0))

        // Ieper and Bedburg with its station are two journeys.
        let trips = try ModelContext(container).fetch(FetchDescriptor<Trip>())
        #expect(Set(trips.map { Set(($0.stays ?? []).map(\.id)) })
                == [[original[1].id], [original[3].id, original[4].id]])
        #expect(trips.count == 2)
        #expect(trips.filter { $0.id == sharedID }.count == 1)
        // The larger journey carries the id on.
        #expect(trips.first { $0.id == sharedID }?.stays?.count == (copies ? 4 : 2))
    }

    // MARK: - Idempotence and failure

    @Test("running the reconciliation again changes nothing")
    func secondRunCommitsNothing() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        let semester = insertSemester(in: ctx)
        _ = seedSemesterTrip(in: ctx)
        _ = seedBaseOnlyTrip(in: ctx)
        try ctx.save()

        let classifier = await makeClassifier(container)
        #expect(await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: semester.id, pinnedTripIDs: [])
            == .committed(stamped: 4, freed: 0, rebuiltTrips: 2, protectedTrips: 0))
        let settled = try storeState(container)

        #expect(await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: semester.id, pinnedTripIDs: [])
            == .committed(stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 0))
        #expect(try storeState(container) == settled)
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
    }

    @Test("a failed read, recovery record or save leaves every stay and trip exactly as it was, and a retry completes the change",
          arguments: ["homes", "temporary homes", "stays", "recovery record", "save"])
    func failureLeavesTheStoreUntouched(failure: String) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        let semester = insertSemester(in: ctx)
        _ = seedSemesterTrip(in: ctx)
        _ = seedBaseOnlyTrip(in: ctx)
        try ctx.save()
        let before = try storeState(container)

        let classifier = await makeClassifier(container)
        switch failure {
        case "homes": classifier.failHomeReadForTesting = true
        case "temporary homes": classifier.failTemporaryHomeReadForTesting = true
        case "stays": classifier.failReconciliationStayReadForTesting = true
        case "recovery record":
            await classifier.setDissolvedRecordSink { _ in throw TemporaryHomeInjectedError() }
        default: await classifier.failNextReconciliationSaveForTesting()
        }
        #expect(await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: semester.id, pinnedTripIDs: []) == .failed)
        #expect(try storeState(container) == before)
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        #expect(await classifier.drainParkedDissolvedTrips().isEmpty)

        classifier.failHomeReadForTesting = false
        classifier.failTemporaryHomeReadForTesting = false
        classifier.failReconciliationStayReadForTesting = false
        await classifier.setDissolvedRecordSink(nil)
        #expect(await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: semester.id, pinnedTripIDs: [])
            == .committed(stamped: 4, freed: 0, rebuiltTrips: 2, protectedTrips: 0))
        #expect(try storeState(container) != before)
    }

    private func trip(_ id: UUID, _ container: ModelContainer) throws -> Trip {
        try #require(try ModelContext(container).fetch(FetchDescriptor<Trip>()).first { $0.id == id })
    }

    @Test("a removal whose save fails leaves the favorited trip beside the freed stays unmarked, the correction in place and the stay it stamped still home, and a retry completes all of it")
    func failedRemovalKeepsTheFavoriteUnmarkedAndTheCorrection() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        let semester = insertSemester(in: ctx)
        let semesterID = semester.id
        let base = [makeStay(in: ctx, at: Self.brussels, startDay: 10, days: 2.5, category: .home,
                             stampedBy: semesterID),
                    makeStay(in: ctx, at: Self.brussels, startDay: 14, days: 1.5, category: .home,
                             stampedBy: semesterID)]
        let side = makeStay(in: ctx, at: Self.ieper, startDay: 13, category: .destination)
        // A day the user demoted with "This wasn't a trip" during the semester.
        let taughtPlace = (lat: 51.30, lon: 4.35)
        let taught = makeStay(in: ctx, at: taughtPlace, startDay: 16, category: .home,
                              stampedBy: semesterID)
        taught.userOverridden = true
        ctx.insert(HomeAreaOverride(
            kind: .include, centerLatitude: taughtPlace.lat, centerLongitude: taughtPlace.lon,
            radiusKm: 2, homeID: semesterID))
        _ = makeStay(in: ctx, at: Self.athens, startDay: 31, category: .home)
        let favorite = makeTrip(in: ctx, [side], complete: true)
        try ctx.save()
        let favoriteID = favorite.id
        try markRemoved(semesterID, in: ctx)
        let before = try storeState(container)

        let classifier = await makeClassifier(container)
        await classifier.failNextReconciliationSaveForTesting()
        #expect(await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: semesterID, pinnedTripIDs: [favoriteID]) == .failed)
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        #expect(try storeState(container) == before)
        #expect(try trip(favoriteID, container).userEdited == false)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<HomeAreaOverride>()) == 1)
        #expect(try stay(taught.id, container).userOverridden)

        #expect(await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: semesterID, pinnedTripIDs: [favoriteID])
            == .committed(stamped: 0, freed: 3, rebuiltTrips: 0, protectedTrips: 1))
        #expect(try trip(favoriteID, container).userEdited)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<HomeAreaOverride>()) == 0)
        for id in base.map(\.id) + [taught.id] {
            let freed = try stay(id, container)
            #expect(freed.category == .unclassified)
            #expect(!freed.userOverridden)
        }
        #expect(try stayIDsByTrip(container) == [favoriteID: [side.id]])
    }

    @Test("with no stay to stamp or free, a removed temporary home's correction is still withdrawn; a failed save leaves it as it was and a retry completes it")
    func correctionWithNoStayToMoveSurvivesAFailedSave() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        let semester = insertSemester(in: ctx)
        let semesterID = semester.id
        // The temporary home is removed; only a correction keyed to it is left.
        ctx.insert(HomeAreaOverride(
            kind: .exclude, centerLatitude: Self.ieper.lat, centerLongitude: Self.ieper.lon,
            radiusKm: 2, homeID: semesterID))
        try ctx.save()
        try markRemoved(semesterID, in: ctx)
        let before = try storeState(container)
        func corrections() throws -> Int {
            try ModelContext(container).fetchCount(FetchDescriptor<HomeAreaOverride>())
        }
        let expected = TripClassifier.TemporaryHomeReconciliationOutcome.committed(
            stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 0)

        let classifier = await makeClassifier(container)
        await classifier.failNextReconciliationSaveForTesting()
        #expect(await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: semesterID, pinnedTripIDs: []) == .failed)
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        #expect(try corrections() == 1)

        #expect(await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: semesterID, pinnedTripIDs: []) == expected)
        #expect(try corrections() == 0)
        #expect(try storeState(container) == before)

        // Nothing is left to write: a replay saves nothing.
        await classifier.failNextReconciliationSaveForTesting()
        #expect(await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: semesterID, pinnedTripIDs: []) == expected)
    }

    // MARK: - Kept trips: marks, distances, provenance

    @Test("a favorited completed trip the user kept against a new temporary home is kept whole and marked edited, as this feature's mark, in the unit's own save: a failed save fails the unit and leaves it unmarked; once the favorite is removed it is still kept, since nothing releases the mark on its own")
    func forwardKeptFavoriteIsMarkedAndStaysKeptOnceUnfavorited() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        let semester = insertSemester(in: ctx)
        let fixture = seedSemesterTrip(in: ctx)
        // Only an explicit keep holds a trip the temporary home covers whole.
        semester.addKeptTrip(fixture.tripID)
        try ctx.save()
        let before = try storeState(container)

        let classifier = await makeClassifier(container)
        // The mark is the only write, so the injected failure fails the unit.
        await classifier.failNextReconciliationSaveForTesting()
        #expect(await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: semester.id, pinnedTripIDs: [fixture.tripID]) == .failed)
        #expect(try trip(fixture.tripID, container).userEdited == false)
        #expect(try storeState(container) == before)
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)

        #expect(await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: semester.id, pinnedTripIDs: [fixture.tripID])
            == .committed(stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 1))
        let marked = try trip(fixture.tripID, container)
        #expect(marked.userEdited)
        #expect(marked.keptByTemporaryHome)
        #expect(try storeState(container) == before)

        // The star is removed and the same reconciliation runs again. A missing
        // favorite is not consent, so there is no automatic release: the trip
        // is not rebuilt into its side trips, and keeps both marks.
        let again = await makeClassifier(container)
        #expect(await again.applyTemporaryHomeChangeCore(
            temporaryHomeID: semester.id, pinnedTripIDs: [])
            == .committed(stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 1))
        #expect(try storeState(container) == before)
        let still = try trip(fixture.tripID, container)
        #expect(still.userEdited)
        #expect(still.keptByTemporaryHome)
    }

    @Test("an open favorite whose dates hold a stay that joins the base is split there: archived with its three members, its stays at the base and the stay inside it home, and its side trip a trip of its own")
    func openFavoriteIsSplitWhenAStayInsideItJoinsTheBase() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        let semester = insertSemester(in: ctx)
        let first = makeStay(in: ctx, at: Self.brussels, startDay: 10, days: 1, category: .destination)
        let side = makeStay(in: ctx, at: Self.ieper, startDay: 13, days: 2, category: .destination)
        let last = makeStay(in: ctx, at: Self.brussels, startDay: 16, days: 4, category: .destination)
        let favoriteID = makeTrip(in: ctx, [first, side, last], complete: false).id
        let loose = makeStay(in: ctx, at: Self.brussels, startDay: 12, days: 0.8, category: .destination)
        try ctx.save()

        let classifier = await makeClassifier(container)
        let box = TemporaryHomeRecordBox()
        await classifier.setDissolvedRecordSink { box.append($0) }
        #expect(await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: semester.id, pinnedTripIDs: [favoriteID])
            == .committed(stamped: 3, freed: 0, rebuiltTrips: 1, protectedTrips: 0))
        let record = try #require(box.records.first)
        #expect(box.records.map(\.id) == [favoriteID])
        #expect(record.stays.map(\.id) == [first.id, side.id, last.id])
        #expect(!record.isComplete)
        #expect(record.wasFavourite == true)
        let trips = try stayIDsByTrip(container)
        #expect(trips[favoriteID] == nil)
        #expect(Array(trips.values) == [[side.id]])
        for id in [first.id, last.id, loose.id] {
            let stamped = try stay(id, container)
            #expect(stamped.category == .home)
            #expect(stamped.trip == nil)
        }
    }

    // With no stale stay the exposure check never ran,
    // so the rebuilt trip's remnant regrouped the favorite beside it.
    @Test("a favorite right after a trip the unit rebuilds, with no home stay between them, is exposed by the rebuilt trip's remnant: it is kept and marked, and the unit and the next ordinary pass leave it its own members and its id")
    func favoriteBesideARebuiltTripsRemnantIsKept() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        let semester = insertSemester(in: ctx, from: 10, until: 11)
        let base = makeStay(in: ctx, at: Self.brussels, startDay: 10, category: .destination)
        let remnant = makeStay(in: ctx, at: Self.paris, startDay: 12, days: 0.5, category: .destination)
        makeTrip(in: ctx, [base, remnant], complete: true)
        let own = [13.0, 14].map {
            makeStay(in: ctx, at: Self.paris, startDay: $0, days: 0.5, category: .destination)
        }
        let favoriteID = makeTrip(in: ctx, own, complete: true).id
        _ = makeStay(in: ctx, at: Self.athens, startDay: 16, category: .home)
        try ctx.save()
        let members = Set(own.map(\.id))

        let classifier = await makeClassifier(container)
        #expect(await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: semester.id, pinnedTripIDs: [favoriteID])
            == .committed(stamped: 1, freed: 0, rebuiltTrips: 1, protectedTrips: 1))
        let kept = try trip(favoriteID, container)
        #expect(kept.userEdited)
        #expect(kept.keptByTemporaryHome)
        #expect(try stayIDsByTrip(container)[favoriteID] == members)
        #expect(try stay(base.id, container).category == .home)

        await StayClassificationInference.TestHook.$availability.withValue(false) {
            _ = await classifier.classifyAndAssembleTripsWithGates(
                maxStaysPerCall: nil, gate: PipelineGate(forTesting: ()))
        }
        #expect(try stayIDsByTrip(container)[favoriteID] == members)
        #expect(try stay(remnant.id, container).trip?.id != favoriteID)
    }

    /// A second temporary home in Paris, saved but not reconciled.
    private func insertParisHome(in ctx: ModelContext, from: Double, until: Double) -> TemporaryHome {
        let row = TemporaryHome(
            label: "Paris", latitude: Self.paris.lat, longitude: Self.paris.lon,
            startedAt: date(day: from), endedAt: date(day: until))
        ctx.insert(row)
        return row
    }

    /// `makeClassifier` that also knows Paris's area.
    private func makeClassifierWithParis(_ container: ModelContainer) async -> TripClassifier {
        let classifier = await makeClassifier(container)
        await classifier.primeShapeForTesting(
            latitude: Self.paris.lat, longitude: Self.paris.lon,
            shape: TemporaryHomeFixture.squareShape(id: 3, around: Self.paris))
        return classifier
    }

    // A remnant still classified home was left out of the
    // remnants, so one that goes back to the pool exposed no favorite. The
    // rebuilding unit may not release another live declaration's stamp:
    // the remnant goes to the pool through that declaration's own unit.
    @Test("a rebuilt trip's member still home, stamped by another temporary home whose new end no longer reaches it, keeps that stamp through the rebuild; that home's own unit frees it, lists the favorite after it as kept and marks it, and the favorite keeps exactly its own members")
    func homeRemnantGoingToThePoolExposesAFavorite() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        let semester = insertSemester(in: ctx, from: 10, until: 11)
        // Paris once ran to day 20; its end is now day 11 and its unit is owed.
        let paris = insertParisHome(in: ctx, from: 2, until: 11)
        let base = makeStay(in: ctx, at: Self.brussels, startDay: 10, category: .destination)
        // Still linked and still home, as Paris's stamp left it.
        let remnant = makeStay(in: ctx, at: Self.paris, startDay: 12, days: 5, category: .home,
                               stampedBy: paris.id)
        makeTrip(in: ctx, [base, remnant], complete: true)
        let own = [18.0, 19].map {
            makeStay(in: ctx, at: Self.paris, startDay: $0, days: 0.5, category: .destination)
        }
        let favoriteID = makeTrip(in: ctx, own, complete: true).id
        _ = makeStay(in: ctx, at: Self.athens, startDay: 22, category: .home)
        try ctx.save()
        let members = Set(own.map(\.id))

        let classifier = await makeClassifierWithParis(container)
        let preview = try #require(await classifier.previewTemporaryHomeChange(
            draft: HomeAnchor(semester), removing: false, pinnedTripIDs: [favoriteID]))
        #expect(!preview.tripsKept.map(\.id).contains(favoriteID))

        #expect(await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: semester.id, pinnedTripIDs: [favoriteID])
            == .committed(stamped: 1, freed: 0, rebuiltTrips: 1, protectedTrips: 0))
        #expect(try !trip(favoriteID, container).userEdited)
        let held = try stay(remnant.id, container)
        #expect(held.category == .home)
        #expect(held.temporaryHomeID == paris.id)

        // Paris's own unit, owed since its end moved.
        let parisPreview = try #require(await classifier.previewTemporaryHomeChange(
            draft: HomeAnchor(paris), removing: false, pinnedTripIDs: [favoriteID]))
        #expect(parisPreview.tripsKept.map(\.id).contains(favoriteID))
        #expect(await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: paris.id, pinnedTripIDs: [favoriteID])
            == .committed(stamped: 0, freed: 1, rebuiltTrips: 0, protectedTrips: 1))
        let kept = try trip(favoriteID, container)
        #expect(kept.userEdited)
        #expect(kept.keptByTemporaryHome)
        #expect(try stayIDsByTrip(container)[favoriteID] == members)
        // Five days with no ring claiming it: a destination, outside the favorite.
        await StayClassificationInference.TestHook.$availability.withValue(false) {
            _ = await classifier.classifyAndAssembleTripsWithGates(
                maxStaysPerCall: nil, gate: PipelineGate(forTesting: ()))
        }
        let rejudged = try stay(remnant.id, container)
        #expect(rejudged.category == .destination)
        #expect(rejudged.trip?.id != favoriteID)
        #expect(try stayIDsByTrip(container)[favoriteID] == members)
    }

    // A remnant another temporary home claims was counted
    // as going to the pool, so it exposed and marked a favorite it bounds.
    @Test("a rebuilt trip's member that another saved temporary home claims becomes home and bounds the favorite after it: the preview does not list the favorite as kept and the unit leaves it unmarked")
    func remnantBecomingHomeDoesNotMarkAFavorite() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        let semester = insertSemester(in: ctx, from: 10, until: 11)
        // Saved; its own unit has not run.
        _ = insertParisHome(in: ctx, from: 12, until: 20)
        let base = makeStay(in: ctx, at: Self.brussels, startDay: 10, category: .destination)
        let remnant = makeStay(in: ctx, at: Self.paris, startDay: 12, days: 0.5, category: .destination)
        makeTrip(in: ctx, [base, remnant], complete: true)
        let ales = (lat: 45.76, lon: 4.84)
        let own = [13.0, 14].map {
            makeStay(in: ctx, at: ales, startDay: $0, days: 0.5, category: .destination)
        }
        let favoriteID = makeTrip(in: ctx, own, complete: true).id
        _ = makeStay(in: ctx, at: Self.athens, startDay: 16, category: .home)
        try ctx.save()

        let classifier = await makeClassifierWithParis(container)
        let preview = try #require(await classifier.previewTemporaryHomeChange(
            draft: HomeAnchor(semester), removing: false, pinnedTripIDs: [favoriteID]))
        #expect(!preview.tripsKept.map(\.id).contains(favoriteID))

        #expect(await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: semester.id, pinnedTripIDs: [favoriteID])
            == .committed(stamped: 1, freed: 0, rebuiltTrips: 1, protectedTrips: 0))
        let stamped = try stay(remnant.id, container)
        #expect(stamped.category == .home)
        #expect(stamped.trip == nil)
        let untouched = try trip(favoriteID, container)
        #expect(!untouched.userEdited)
        #expect(!untouched.keptByTemporaryHome)
    }

    // A remnant a routine place claims was counted as going
    // to the pool, so it exposed and marked a favorite it never reaches.
    @Test("a rebuilt trip's member that a routine place claims becomes routine, neither in the pool nor a boundary: the preview does not list the favorite after it as kept and the unit leaves it unmarked")
    func remnantBecomingRoutineDoesNotMarkAFavorite() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        let semester = insertSemester(in: ctx, from: 10, until: 11)
        // Saved; its own reconciliation has not run.
        ctx.insert(RoutinePlace(label: "Office", latitude: Self.paris.lat, longitude: Self.paris.lon,
                                startedAt: date(day: 12)))
        let base = makeStay(in: ctx, at: Self.brussels, startDay: 10, category: .destination)
        let remnant = makeStay(in: ctx, at: Self.paris, startDay: 12, days: 0.5, category: .destination)
        makeTrip(in: ctx, [base, remnant], complete: true)
        let ales = (lat: 45.76, lon: 4.84)
        let own = [13.0, 14].map {
            makeStay(in: ctx, at: ales, startDay: $0, days: 0.5, category: .destination)
        }
        let favoriteID = makeTrip(in: ctx, own, complete: true).id
        _ = makeStay(in: ctx, at: Self.athens, startDay: 16, category: .home)
        try ctx.save()

        let classifier = await makeClassifier(container)
        let preview = try #require(await classifier.previewTemporaryHomeChange(
            draft: HomeAnchor(semester), removing: false, pinnedTripIDs: [favoriteID]))
        #expect(!preview.tripsKept.map(\.id).contains(favoriteID))

        #expect(await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: semester.id, pinnedTripIDs: [favoriteID])
            == .committed(stamped: 1, freed: 0, rebuiltTrips: 1, protectedTrips: 0))
        #expect(try stay(remnant.id, container).category == .routine)
        let untouched = try trip(favoriteID, container)
        #expect(!untouched.userEdited)
        #expect(!untouched.keptByTemporaryHome)
    }

    @Test("the unit settles the members of trips the user kept against it: one a pass reset and never judged, and one the pre-filter stamped home while still linked, are judged again without the pre-filter and stay in their trips, and nothing is left for the next pass to repair")
    func unitSettlesKeptMembers() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        let semester = insertSemester(in: ctx)
        let semesterID = semester.id
        let reset = makeStay(in: ctx, at: Self.ieper, startDay: 13, category: .unclassified)
        let first = makeTrip(in: ctx, [
            makeStay(in: ctx, at: Self.brussels, startDay: 10, days: 1, category: .destination), reset,
        ], complete: true)
        let stamped = makeStay(in: ctx, at: Self.brussels, startDay: 22, days: 1, category: .home,
                               stampedBy: semesterID)
        let second = makeTrip(in: ctx, [
            makeStay(in: ctx, at: Self.ieper, startDay: 20, category: .destination), stamped,
        ], complete: true)
        _ = makeStay(in: ctx, at: Self.athens, startDay: 30, category: .home)
        // Both already marked, by the worker's save or an earlier unit, and
        // kept by the user against the temporary home.
        for trip in [first, second] {
            trip.userEdited = true
            trip.keptByTemporaryHome = true
            semester.addKeptTrip(trip.id)
        }
        try ctx.save()
        let (firstID, secondID) = (first.id, second.id)

        let classifier = await makeClassifier(container)
        #expect(await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: semesterID, pinnedTripIDs: [])
            == .committed(stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 2))
        for (id, tripID) in [(reset.id, firstID), (stamped.id, secondID)] {
            let settled = try stay(id, container)
            #expect([StayCategory.destination, .transit].contains(settled.category))
            #expect(settled.trip?.id == tripID)
            #expect(settled.temporaryHomeID == nil)
        }
        #expect(await classifier.assemblyInvariantViolatedForTesting() == false)
        // Settled once: a replay has nothing to write.
        await classifier.failNextReconciliationSaveForTesting()
        #expect(await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: semesterID, pinnedTripIDs: [])
            == .committed(stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 2))
    }

    // With the declaration removed no
    // plan keeps the trip, so its stamped member was never settled.
    @Test("a trip a temporary home kept earlier still has its stamped member settled once that temporary home is removed: the member stays in the trip, records no temporary home, and nothing is left for the next pass to repair")
    func removalSettlesAnEarlierKeptTripsStampedMember() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        let semester = insertSemester(in: ctx)
        let semesterID = semester.id
        let stamped = makeStay(in: ctx, at: Self.brussels, startDay: 22, days: 1, category: .home,
                               stampedBy: semesterID)
        let kept = makeTrip(in: ctx, [
            makeStay(in: ctx, at: Self.ieper, startDay: 20, category: .destination), stamped,
        ], complete: true)
        _ = makeStay(in: ctx, at: Self.athens, startDay: 30, category: .home)
        kept.userEdited = true
        kept.keptByTemporaryHome = true
        try ctx.save()
        let keptID = kept.id
        // Removed before the unit that would have settled the member ran.
        try markRemoved(semesterID, in: ctx)

        let classifier = await makeClassifier(container)
        #expect(await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: semesterID, pinnedTripIDs: []) == .committed(
                stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 0))
        let settled = try stay(stamped.id, container)
        #expect([StayCategory.destination, .transit].contains(settled.category))
        #expect(settled.trip?.id == keptID)
        #expect(settled.temporaryHomeID == nil)
        let after = try trip(keptID, container)
        #expect(after.userEdited)
        #expect(after.keptByTemporaryHome)
        #expect(await classifier.assemblyInvariantViolatedForTesting() == false)
    }

    @Test("a reconciliation replayed in the background with the favorite gone, as an import's debt drains it, never releases a trip the user kept against the temporary home: both marks, its members and its id stay")
    func backgroundReplayNeverReleasesAKeptTrip() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        let semester = insertSemester(in: ctx, until: nil)
        let semesterID = semester.id
        let members = [
            makeStay(in: ctx, at: Self.brussels, startDay: 10, days: 2.5, category: .destination),
            makeStay(in: ctx, at: Self.brussels, startDay: 14, days: 1.5, category: .destination),
        ]
        let kept = makeTrip(in: ctx, members, complete: false)
        kept.userEdited = true
        kept.keptByTemporaryHome = true
        semester.addKeptTrip(kept.id)
        try ctx.save()
        let keptID = kept.id
        let owed = CoverageReconciliationQueue.stage(.temporaryHome, id: semesterID, defaults: defaults)
        let debt = TemporaryHomeDebt(entry: owed.entry, defaults: defaults)

        let classifier = await makeClassifier(container)
        let outcome = await StayClassificationInference.TestHook.$availability.withValue(false) {
            await classifier.applyTemporaryHomeChange(
                temporaryHomeID: semesterID, pinnedTripIDs: { [] },
                gate: PipelineGate(forTesting: ()), onSettled: { debt.settle() })
        }
        #expect(outcome == .committed(stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 1))
        #expect(debt.settled == 1)
        #expect(try stayIDsByTrip(container) == [keptID: Set(members.map(\.id))])
        let after = try trip(keptID, container)
        #expect(after.userEdited)
        #expect(after.keptByTemporaryHome)
        for member in members {
            #expect(try stay(member.id, container).category == .destination)
        }
    }

    /// The flags of an existing trip row, then of the record, then what the
    /// restored trip must read. Nil existing flags restore into a fresh row.
    @Test("a restore keeps a temporary home's mark only when every edited side had it",
          arguments: [
            [nil, nil, true, true, true, true],
            [nil, nil, true, false, true, false],
            [true, false, true, true, true, false],
            [false, false, true, true, true, true],
            [true, true, true, true, true, true],
            [true, true, false, false, true, true],
          ] as [[Bool?]])
    func restoreKeepsTheMarkOnlyWhenEveryEditedSideHadIt(_ flags: [Bool?]) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let member = makeStay(in: ctx, at: Self.ieper, startDay: 13, category: .unclassified)
        let tripID = UUID()
        if let edited = flags[0], let kept = flags[1] {
            // The row came back by sync without its stays.
            let returned = Trip(startDate: date(day: 13))
            returned.id = tripID
            returned.userEdited = edited
            returned.keptByTemporaryHome = kept
            ctx.insert(returned)
        }
        try ctx.save()
        let record = DissolvedTripRecord(
            id: tripID, dissolvedAt: date(day: 20), displayName: "Ieper",
            startDate: member.startTime, endDate: member.endTime, isComplete: true,
            destinationSummary: "Ieper", countryCodes: "BE", classifiedByAI: false,
            aiGeneratedTitle: nil, aiGeneratedSummary: nil, summarySourceRaw: nil,
            sourceRaw: DataSource.liveSLC.rawValue, customName: nil,
            userEdited: flags[2] ?? false, keptByTemporaryHome: flags[3],
            stays: [.init(id: member.id, categoryRaw: "destination", orderInTrip: 0)])

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.restoreDissolvedTrip(record, markStaysSacred: false) == .restored)
        let restored = try trip(tripID, container)
        #expect(restored.userEdited == flags[4])
        #expect(restored.keptByTemporaryHome == flags[5])
        #expect(try stayIDsByTrip(container)[tripID] == [member.id])
    }

    // A returned row that already held a member took the
    // populated path, which never merged the record's marks.
    @Test("a restore into a returned trip that already holds one of the record's members keeps the temporary home's mark the record carries")
    func restoreIntoAPopulatedReturnedTripKeepsTheMark() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let present = makeStay(in: ctx, at: Self.ieper, startDay: 13, category: .destination)
        let missing = makeStay(in: ctx, at: Self.ieper, startDay: 14, category: .unclassified)
        // The row came back by sync with one of its stays and neither flag.
        let returned = makeTrip(in: ctx, [present], complete: true)
        let tripID = returned.id
        #expect(!returned.userEdited)
        #expect(!returned.keptByTemporaryHome)
        try ctx.save()
        let record = DissolvedTripRecord(
            id: tripID, dissolvedAt: date(day: 20), displayName: "Ieper",
            startDate: present.startTime, endDate: missing.endTime, isComplete: true,
            destinationSummary: "Ieper", countryCodes: "BE", classifiedByAI: false,
            aiGeneratedTitle: nil, aiGeneratedSummary: nil, summarySourceRaw: nil,
            sourceRaw: DataSource.liveSLC.rawValue, customName: nil,
            userEdited: true, keptByTemporaryHome: true,
            stays: [.init(id: present.id, categoryRaw: "destination", orderInTrip: 0),
                    .init(id: missing.id, categoryRaw: "destination", orderInTrip: 1)])

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.restoreDissolvedTrip(record, markStaysSacred: false) == .restored)
        let restored = try trip(tripID, container)
        #expect(restored.userEdited)
        #expect(restored.keptByTemporaryHome)
        #expect(try stayIDsByTrip(container)[tripID] == [present.id, missing.id])
    }

    // The populated path merged the record's ordinary edit
    // mark too, which it never did before temporary homes.
    @Test("with no temporary home anywhere, a restore into a returned trip that already holds one of the record's members does not take the record's own edit mark, as before")
    func ordinaryPopulatedRestoreKeepsItsPreviousBehavior() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let present = makeStay(in: ctx, at: Self.ieper, startDay: 13, category: .destination)
        let missing = makeStay(in: ctx, at: Self.ieper, startDay: 14, category: .unclassified)
        // The row came back by sync with one of its stays and neither flag.
        let returned = makeTrip(in: ctx, [present], complete: true)
        let tripID = returned.id
        try ctx.save()
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<TemporaryHome>()) == 0)
        // A demotion record of the user's own edit: no temporary home's mark.
        let record = DissolvedTripRecord(
            id: tripID, dissolvedAt: date(day: 20), displayName: "Ieper",
            startDate: present.startTime, endDate: missing.endTime, isComplete: true,
            destinationSummary: "Ieper", countryCodes: "BE", classifiedByAI: false,
            aiGeneratedTitle: nil, aiGeneratedSummary: nil, summarySourceRaw: nil,
            sourceRaw: DataSource.liveSLC.rawValue, customName: nil,
            userEdited: true, keptByTemporaryHome: nil,
            stays: [.init(id: present.id, categoryRaw: "destination", orderInTrip: 0),
                    .init(id: missing.id, categoryRaw: "destination", orderInTrip: 1)])

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.restoreDissolvedTrip(record, markStaysSacred: false) == .restored)
        let restored = try trip(tripID, container)
        #expect(!restored.userEdited)
        #expect(!restored.keptByTemporaryHome)
        #expect(try stayIDsByTrip(container)[tripID] == [present.id, missing.id])
    }

    // Populated twins returned before any merge, so the
    // keep decision lived only in a record the caller may prune.
    @Test("a restore that finds two populated trip rows sharing the record's id reports the trip already back and gives each row the temporary home's keep mark the record carries")
    func populatedTwinsTakeTheRecordedKeepMark() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let first = makeStay(in: ctx, at: Self.ieper, startDay: 13, category: .destination)
        let second = makeStay(in: ctx, at: Self.ieper, startDay: 14, category: .destination)
        // Two physical rows of one trip, each back with one member and neither flag.
        let one = makeTrip(in: ctx, [first], complete: true)
        let twin = makeTrip(in: ctx, [second], complete: true)
        twin.id = one.id
        let tripID = one.id
        try ctx.save()
        let record = DissolvedTripRecord(
            id: tripID, dissolvedAt: date(day: 20), displayName: "Ieper",
            startDate: first.startTime, endDate: second.endTime, isComplete: true,
            destinationSummary: "Ieper", countryCodes: "BE", classifiedByAI: false,
            aiGeneratedTitle: nil, aiGeneratedSummary: nil, summarySourceRaw: nil,
            sourceRaw: DataSource.liveSLC.rawValue, customName: nil,
            userEdited: true, keptByTemporaryHome: true,
            stays: [.init(id: first.id, categoryRaw: "destination", orderInTrip: 0),
                    .init(id: second.id, categoryRaw: "destination", orderInTrip: 1)])

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.restoreDissolvedTrip(record, markStaysSacred: false) == .alreadyExists)
        let rows = try ModelContext(container).fetch(FetchDescriptor<Trip>()).filter { $0.id == tripID }
        #expect(rows.count == 2)
        for row in rows {
            #expect(row.userEdited)
            #expect(row.keptByTemporaryHome)
        }
    }

    @Test("the recovery record of a trip a temporary home kept carries the mark, and a queue file written before it decodes the mark as absent")
    func dissolvedRecordCarriesTheMark() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        _ = insertSemester(in: ctx)
        let kept = makeTrip(in: ctx, [
            makeStay(in: ctx, at: Self.ieper, startDay: 50, category: .destination),
        ], complete: true)
        kept.userEdited = true
        kept.keptByTemporaryHome = true
        try ctx.save()
        let (keptID, keptRow) = (kept.id, kept.persistentModelID)

        // This Wasn't a Trip parks the kept trip for its undo.
        let classifier = await makeClassifier(container)
        let box = TemporaryHomeRecordBox()
        await classifier.setDissolvedRecordSink { box.append($0) }
        _ = await classifier.demoteTripToHomeArea(tripID: keptID, tripIdentifier: keptRow)
        let record = try #require(box.records.first)
        #expect(record.id == keptID)
        #expect(record.userEdited)
        #expect(record.keptByTemporaryHome == true)

        var legacy = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        legacy["keptByTemporaryHome"] = nil
        let decoded = try JSONDecoder().decode(
            DissolvedTripRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.keptByTemporaryHome == nil)
        #expect(decoded.id == record.id)
    }

    @Test("a favorited side trip kept through the removal of the temporary home it left from is measured from the real home again, the home its page then names")
    func keptTripIsMeasuredFromTheRealHomeAfterRemoval() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        let semester = insertSemester(in: ctx)
        let semesterID = semester.id
        _ = makeStay(in: ctx, at: Self.brussels, startDay: 10, days: 2.5, category: .home,
                     stampedBy: semesterID)
        let side = makeStay(in: ctx, at: Self.ieper, startDay: 13, category: .destination)
        // As assembly stamped it while the base was home: 111 km from Brussels.
        side.distanceFromHomeKm = 111
        _ = makeStay(in: ctx, at: Self.brussels, startDay: 14, days: 1.5, category: .home,
                     stampedBy: semesterID)
        _ = makeStay(in: ctx, at: Self.athens, startDay: 31, category: .home)
        let favoriteID = makeTrip(in: ctx, [side], complete: true).id
        try ctx.save()
        try markRemoved(semesterID, in: ctx)

        let classifier = await makeClassifier(container)
        #expect(await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: semesterID, pinnedTripIDs: [favoriteID])
            == .committed(stamped: 0, freed: 2, rebuiltTrips: 0, protectedTrips: 1))

        let kept = try stay(side.id, container)
        #expect(kept.trip?.id == favoriteID)
        #expect(kept.category == .destination)
        // The last home stay before it is now the one in Athens, about 2,150 km away.
        #expect(kept.distanceFromHomeKm > 2000, "\(kept.distanceFromHomeKm) km")
    }

    @Test("a trip with a hidden photo kept when the temporary home's end moves before it is measured from the base it left, the last home stay before it, and not from the real home")
    func keptTripAfterAnEarlierEndIsMeasuredFromTheBaseItLeft() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        let semester = insertSemester(in: ctx)
        _ = makeStay(in: ctx, at: Self.brussels, startDay: 14, days: 6, category: .home,
                     stampedBy: semester.id)
        _ = makeStay(in: ctx, at: Self.brussels, startDay: 24, days: 2.5, category: .home,
                     stampedBy: semester.id)
        // Its stored distance starts at zero, so the figure below is the unit's own.
        let side = makeStay(in: ctx, at: Self.bedburg, startDay: 27, days: 1.5, category: .destination)
        _ = makeStay(in: ctx, at: Self.brussels, startDay: 29, days: 5, category: .home,
                     stampedBy: semester.id)
        _ = makeStay(in: ctx, at: Self.athens, startDay: 36, category: .home)
        let curatedID = makeTrip(in: ctx, [side], complete: true).id
        ctx.insert(HiddenPhoto(localIdentifier: "asset-1", tripID: curatedID))
        try ctx.save()
        // The user moves the end to day 22.
        semester.endedAt = date(day: 22)
        try ctx.save()

        let classifier = await makeClassifier(container)
        #expect(await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: semester.id, pinnedTripIDs: [])
            == .committed(stamped: 0, freed: 2, rebuiltTrips: 0, protectedTrips: 1))

        #expect(try trip(curatedID, container).userEdited)
        let kept = try stay(side.id, container)
        #expect(kept.trip?.id == curatedID)
        // Brussels to the side trip's town is about 140 km; Athens is over 2,000 km away.
        #expect(abs(kept.distanceFromHomeKm - 140) < 3, "\(kept.distanceFromHomeKm) km")
    }

    @Test("trips rebuilt out of a trip the model had classified are not flagged as model-classified: the rules judged their stays again, so they count for Enhance History")
    func rebuiltTripsDoNotInheritModelProvenance() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        let semester = insertSemester(in: ctx)
        let fixture = seedSemesterTrip(in: ctx)
        try ctx.save()
        let original = try #require(try ctx.fetch(FetchDescriptor<Trip>()).first)
        original.classifiedByAI = true
        try ctx.save()

        let classifier = await makeClassifier(container)
        #expect(await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: semester.id, pinnedTripIDs: [])
            == .committed(stamped: 3, freed: 0, rebuiltTrips: 1, protectedTrips: 0))

        let rebuilt = try ModelContext(container).fetch(FetchDescriptor<Trip>())
        #expect(rebuilt.count == 2)
        #expect(rebuilt.allSatisfy { !$0.classifiedByAI })
        // The id still follows the larger side trip.
        #expect(rebuilt.filter { $0.id == fixture.tripID }.count == 1)
    }

    // MARK: - Inside a real home's declared circle

    /// A temporary home in the village, days 10 to 100, as its reconciliation
    /// left the store: its stays there are home and record it; a day the user
    /// demoted with "This wasn't a trip" is home, overridden and records it,
    /// with its correction keyed to the temporary home; and two home stays at
    /// the same spot predate it, stamped under the real home's old circle,
    /// claimed by no area now and recording no temporary home.
    private struct VillageFixture {
        let id: UUID
        /// Days 20, 50 and 90.
        let own: [UUID]
        /// Day 30.
        let taught: UUID
        /// Days 2 and 5.
        let legacy: [UUID]
    }

    private func seedVillage(in ctx: ModelContext) -> VillageFixture {
        seedRealHome(in: ctx)
        let row = TemporaryHome(
            label: "Village", latitude: Self.village.lat, longitude: Self.village.lon,
            startedAt: date(day: 10), endedAt: date(day: 100))
        // Whole fixture days: a day ended here ends at its last second, UTC.
        row.timeZoneIdentifier = "GMT"
        ctx.insert(row)
        let own = [20.0, 50, 90].map {
            makeStay(in: ctx, at: Self.village, startDay: $0, category: .home, stampedBy: row.id).id
        }
        let taught = makeStay(in: ctx, at: Self.nearVillage, startDay: 30, category: .home,
                              stampedBy: row.id)
        taught.userOverridden = true
        ctx.insert(HomeAreaOverride(
            kind: .include, centerLatitude: Self.nearVillage.lat,
            centerLongitude: Self.nearVillage.lon, radiusKm: 1, homeID: row.id))
        let legacy = [2.0, 5].map {
            makeStay(in: ctx, at: Self.village, startDay: $0, category: .home).id
        }
        return VillageFixture(id: row.id, own: own, taught: taught.id, legacy: legacy)
    }

    private func expectHome(
        _ ids: [UUID], _ container: ModelContainer,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        for id in ids {
            #expect(try stay(id, container).category == .home, sourceLocation: sourceLocation)
        }
    }

    @Test("removing a temporary home that lies inside the real home's declared circle frees the stays it had claimed and the stay its correction had stamped, deletes that correction, and leaves the older home stays at the same spot home; the removal dialog's preview counts the same stays")
    func removalInsideTheRealHomesCircleFreesWhatItHadClaimed() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let fixture = seedVillage(in: ctx)
        try ctx.save()

        // What the confirmation shows before the user removes it.
        let stored = try #require(try HomeAnchors.temporaryHomes(in: ModelContext(container)).first)
        let preview = try #require(await makeClassifierWithVillage(container)
            .previewTemporaryHomeChange(draft: stored, removing: true, pinnedTripIDs: []))
        #expect(preview.staysLeaving == 4)

        // Remove Temporary Home, as Settings writes it, then its reconciliation.
        let removal = TemporaryHomeSaveWorker.apply(
            .removing(fixture.id, now: date(day: 120)), context: ModelContext(container),
            pendingDefaults: defaults)
        #expect(removal.pendingReconciliation?.id == fixture.id)
        let classifier = await makeClassifierWithVillage(container)
        #expect(await reconcile(classifier, fixture.id)
                == .committed(stamped: 0, freed: 4, rebuiltTrips: 0, protectedTrips: 0))

        for id in fixture.own + [fixture.taught] {
            let freed = try stay(id, container)
            #expect(freed.category == .unclassified)
            #expect(freed.temporaryHomeID == nil)
            #expect(!freed.userOverridden)
        }
        try expectHome(fixture.legacy, container)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<HomeAreaOverride>()) == 0)
        // A replay, as the queue's drain runs one after a kill, finds nothing to do.
        #expect(await reconcile(classifier, fixture.id)
                == .committed(stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 0))
    }

    @Test("ending a temporary home inside the real home's declared circle earlier frees its stays after the new end, and keeps its earlier stay, the stay its correction stamped and the older home stays at the same spot")
    func earlierEndInsideTheRealHomesCircleFreesTheLaterStays() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let fixture = seedVillage(in: ctx)
        try ctx.save()

        // End on day 40, as the card writes it, then its reconciliation.
        let ended = TemporaryHomeSaveWorker.apply(
            .ending(fixture.id, on: date(day: 40.5), now: date(day: 120)),
            context: ModelContext(container), pendingDefaults: defaults)
        #expect(ended.pendingReconciliation?.id == fixture.id)
        let classifier = await makeClassifierWithVillage(container)
        #expect(await reconcile(classifier, fixture.id)
                == .committed(stamped: 0, freed: 2, rebuiltTrips: 0, protectedTrips: 0))

        try expectHome([fixture.own[0]], container)
        for id in fixture.own.dropFirst() {
            #expect(try stay(id, container).category == .unclassified)
        }
        // Day 30 is still inside the dates: the correction keeps applying.
        let taught = try stay(fixture.taught, container)
        #expect(taught.category == .home)
        #expect(taught.userOverridden)
        try expectHome(fixture.legacy, container)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<HomeAreaOverride>()) == 1)
    }

    @Test("moving a temporary home's pin out of the real home's declared circle frees the stays at the old place and makes the stay at the new place home, and the form's preview already counts both while the reconciliation is still owed")
    func pinMovedOutOfTheRealHomesCircleFreesTheOldPlace() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let fixture = seedVillage(in: ctx)
        let arrived = makeStay(in: ctx, at: Self.brussels, startDay: 60, category: .destination)
        try ctx.save()

        // The pin moves to Brussels, as the form saves it; the dates stay.
        let moved = TemporaryHomeSaveWorker.apply(
            TemporaryHomeSavePayload(
                target: .edit(fixture.id), label: "Village",
                latitude: Self.brussels.lat, longitude: Self.brussels.lon,
                locality: "Brussels", administrativeArea: nil, country: "Belgium",
                isoCountryCode: "BE", startedAt: date(day: 10), endedAt: date(day: 100),
                timeZoneIdentifier: "GMT", now: date(day: 120)),
            context: ModelContext(container), pendingDefaults: defaults)
        #expect(moved.pendingReconciliation?.id == fixture.id)

        // Reopening the form before the reconciliation ran: the row as saved.
        let saved = try #require(try HomeAnchors.temporaryHomes(in: ModelContext(container)).first)
        #expect(saved.latitude == Self.brussels.lat)
        let preview = try #require(await makeClassifierWithVillage(container)
            .previewTemporaryHomeChange(draft: saved, removing: false, pinnedTripIDs: []))
        #expect(preview.staysLeaving == 3)
        #expect(preview.staysJoining == 1)

        let classifier = await makeClassifierWithVillage(container)
        #expect(await reconcile(classifier, fixture.id)
                == .committed(stamped: 1, freed: 3, rebuiltTrips: 0, protectedTrips: 0))
        for id in fixture.own {
            #expect(try stay(id, container).category == .unclassified)
        }
        let stamped = try stay(arrived.id, container)
        #expect(stamped.category == .home)
        #expect(stamped.trip == nil)
        #expect(stamped.temporaryHomeID == fixture.id)
        try expectHome(fixture.legacy, container)
    }

    @Test("home stays at a spot inside the real home's declared circle that predate a temporary home declared there stay home when it is added, when its start is edited and when it is removed, also one that predates the real home, while the stay it did claim joins it and leaves it")
    func olderHomeStaysAtTheSpotSurviveAddEditAndRemoval() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        let legacy = [-2000.0, 2, 5].map {
            makeStay(in: ctx, at: Self.village, startDay: $0, category: .home).id
        }
        let visit = makeStay(in: ctx, at: Self.village, startDay: 20, category: .destination)
        try ctx.save()
        func payload(
            _ target: TemporaryHomeSavePayload.Target, from: Double
        ) -> TemporaryHomeSavePayload {
            TemporaryHomeSavePayload(
                target: target, label: "Village",
                latitude: Self.village.lat, longitude: Self.village.lon,
                locality: nil, administrativeArea: nil, country: nil, isoCountryCode: nil,
                startedAt: date(day: from), endedAt: date(day: 100),
                timeZoneIdentifier: "GMT", now: date(day: 120))
        }

        // Added for days 10 to 100.
        let added = TemporaryHomeSaveWorker.apply(
            payload(.add, from: 10), context: ModelContext(container), pendingDefaults: defaults)
        let id = try #require(added.pendingReconciliation?.id)
        #expect(await reconcile(await makeClassifierWithVillage(container), id)
                == .committed(stamped: 1, freed: 0, rebuiltTrips: 0, protectedTrips: 0))
        try expectHome(legacy + [visit.id], container)
        // Only the stay it made home records it.
        #expect(try stay(visit.id, container).temporaryHomeID == id)
        for older in legacy { #expect(try stay(older, container).temporaryHomeID == nil) }

        // The start moves to day 12.
        let edited = TemporaryHomeSaveWorker.apply(
            payload(.edit(id), from: 12), context: ModelContext(container),
            pendingDefaults: defaults)
        #expect(edited.pendingReconciliation?.id == id)
        #expect(await reconcile(await makeClassifierWithVillage(container), id)
                == .committed(stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 0))
        try expectHome(legacy + [visit.id], container)

        // Removed.
        let removed = TemporaryHomeSaveWorker.apply(
            .removing(id, now: date(day: 121)), context: ModelContext(container),
            pendingDefaults: defaults)
        #expect(removed.pendingReconciliation?.id == id)
        #expect(await reconcile(await makeClassifierWithVillage(container), id)
                == .committed(stamped: 0, freed: 1, rebuiltTrips: 0, protectedTrips: 0))
        try expectHome(legacy, container)
        #expect(try stay(visit.id, container).category == .unclassified)
    }

    @Test("when the home stays of a removed temporary home record no temporary home, as stays a build before V20 stamped do, its removal frees none of them inside the real home's declared circle, the stay its correction stamped included")
    func removalWithNoRecordedCoverageFreesNothingInsideTheCircle() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let fixture = seedVillage(in: ctx)
        try ctx.save()
        for stay in try ctx.fetch(FetchDescriptor<Stay>()) { stay.temporaryHomeID = nil }
        try markRemoved(fixture.id, in: ctx)

        let classifier = await makeClassifierWithVillage(container)
        #expect(await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: fixture.id, pinnedTripIDs: [])
            == .committed(stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 0))
        try expectHome(fixture.own + [fixture.taught] + fixture.legacy, container)
        #expect(try stay(fixture.taught, container).userOverridden)
    }

    @Test("the gated entry point settles a removal's debt only when its unit commits: a unit that fails keeps the debt and the correction for the retry, and the retry withdraws the correction and settles")
    func entryPointSettlesTheDebtOnlyOnCommit() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        let semesterID = insertSemester(in: ctx).id
        // Only a correction is left of it: no stay moves, so no pipeline pass follows.
        ctx.insert(HomeAreaOverride(
            kind: .exclude, centerLatitude: Self.ieper.lat, centerLongitude: Self.ieper.lon,
            radiusKm: 2, homeID: semesterID))
        try ctx.save()
        let removal = TemporaryHomeSaveWorker.apply(
            .removing(semesterID, now: date(day: 120)), context: ModelContext(container),
            pendingDefaults: defaults)
        #expect(!removal.failed)
        let owed = try #require(removal.pendingReconciliation)
        #expect(CoverageReconciliationQueue.pending(defaults: defaults) == [owed])
        // Settles it as Settings does, once the unit commits.
        let debt = TemporaryHomeDebt(entry: owed, defaults: defaults)

        let classifier = await makeClassifier(container)
        await classifier.failNextReconciliationSaveForTesting()
        #expect(await classifier.applyTemporaryHomeChange(
            temporaryHomeID: semesterID, pinnedTripIDs: { [] },
            gate: PipelineGate(forTesting: ()),
            onSettled: { debt.settle() }) == .failed)
        #expect(debt.settled == 0)
        #expect(CoverageReconciliationQueue.pending(defaults: defaults) == [owed])
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<HomeAreaOverride>()) == 1)

        #expect(await classifier.applyTemporaryHomeChange(
            temporaryHomeID: semesterID, pinnedTripIDs: { [] },
            gate: PipelineGate(forTesting: ()),
            onSettled: { debt.settle() })
            == .committed(stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 0))
        #expect(debt.settled == 1)
        #expect(CoverageReconciliationQueue.pending(defaults: defaults).isEmpty)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<HomeAreaOverride>()) == 0)
    }

    // MARK: - Preview

    @Test("the preview of a new temporary home reports the stays and trips the reconciliation then changes, and leaves the store untouched")
    func previewMatchesExecution() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        let rebuilt = seedSemesterTrip(in: ctx)
        let absorbed = seedBaseOnlyTrip(in: ctx)
        // A renamed trip that holds a stay at the base: split, and listed with why.
        let keptBase = makeStay(in: ctx, at: Self.brussels, startDay: 70, days: 2, category: .destination)
        let keptSide = makeStay(in: ctx, at: Self.ieper, startDay: 73, category: .destination)
        _ = makeStay(in: ctx, at: Self.athens, startDay: 75, category: .home)
        let kept = makeTrip(in: ctx, [keptBase, keptSide], complete: true)
        kept.customName = "Winter in Flanders"
        // An earlier holiday in the same city, before the proposed dates.
        let holiday = makeStay(in: ctx, at: Self.brussels, startDay: 3, days: 1, category: .destination)
        _ = makeStay(in: ctx, at: Self.athens, startDay: 6, category: .home)
        let holidayTrip = makeTrip(in: ctx, [holiday], complete: true)
        try ctx.save()
        let before = try storeState(container)

        // The row is not saved yet: the sheet previews a draft.
        let draft = HomeAnchor(
            id: UUID(), kind: .temporary, label: "Semester",
            latitude: Self.brussels.lat, longitude: Self.brussels.lon, radiusKm: 25,
            locality: nil, isoCountryCode: nil,
            startedAt: date(day: 10), endedAt: date(day: 100))
        let classifier = await makeClassifier(container)
        let preview = try #require(await classifier.previewTemporaryHomeChange(
            draft: draft, removing: false, pinnedTripIDs: []))

        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        #expect(try storeState(container) == before)
        #expect(preview.staysJoining == 5)
        #expect(preview.staysLeaving == 0)
        #expect(preview.tripsRebuilt.map(\.id) == [rebuilt.tripID, absorbed.tripID])
        #expect(preview.tripsRebuilt.allSatisfy { $0.reasons.isEmpty })
        // No stay leaves, so no trip is merged into a longer one.
        #expect(preview.tripsMerged.isEmpty)
        #expect(preview.tripsKept.isEmpty)
        #expect(preview.tripsSplit.map(\.id) == [kept.id])
        #expect(preview.tripsSplit.first?.name == "Winter in Flanders")
        #expect(preview.tripsSplit.first?.reasons == [.customName])
        #expect(preview.tripsSplit.first?.start == date(day: 70))
        #expect(preview.areaIsCityBoundary)
        // The area's first stay is the earlier holiday, outside the dates.
        #expect(preview.firstStayInArea == holiday.startTime)
        #expect(preview.lastStayInArea == keptBase.endTime)

        // Saving that draft and reconciling does what the preview said.
        let semester = insertSemester(in: ctx)
        semester.id = draft.id
        try ctx.save()
        let outcome = await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: draft.id, pinnedTripIDs: [])
        #expect(outcome == .committed(
            stamped: preview.staysJoining, freed: preview.staysLeaving,
            rebuiltTrips: preview.tripsRebuilt.count + preview.tripsSplit.count,
            protectedTrips: preview.tripsKept.count))
        let after = try storeState(container)
        #expect(after.stays.values.filter { $0.category == "home" }.count
                == before.stays.values.filter { $0.category == "home" }.count + 5)
        #expect(!after.tripIDs.contains(kept.id))
        // The earlier holiday is outside the dates: still its own trip.
        #expect(after.stays[holiday.id] == StayState(category: "destination", tripID: holidayTrip.id))

        // Removal previews as the reverse, and the reconciliation agrees.
        let removal = try #require(await classifier.previewTemporaryHomeChange(
            draft: draft, removing: true, pinnedTripIDs: []))
        #expect(removal.staysJoining == 0)
        #expect(removal.staysLeaving == 5)
        #expect(removal.tripsRebuilt.isEmpty)
        #expect(removal.tripsKept.isEmpty)
        #expect(removal.tripsSplit.isEmpty)
        // The side trips the declaration made would fold back into longer
        // trips: the dialog names them. The holiday, between two stays at the
        // real home, is not touched.
        #expect(removal.tripsMerged.map(\.start) == [date(day: 13), date(day: 21), date(day: 73)])
        #expect(removal.tripsMerged[1].id == rebuilt.tripID)
        #expect(removal.tripsMerged.allSatisfy { $0.reasons.isEmpty })
        #expect(try storeState(container) == after)
        try markRemoved(draft.id, in: ctx)
        #expect(await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: draft.id, pinnedTripIDs: [])
            == .committed(stamped: 0, freed: removal.staysLeaving, rebuiltTrips: 0, protectedTrips: 0))
    }

    @Test("a place with no city boundary previews as the fallback area, and an unreadable store previews as nothing")
    func previewReportsFallbackAreaAndFailedReads() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        try ctx.save()
        let village = (lat: 45.0, lon: 10.0)
        let draft = HomeAnchor(
            id: UUID(), kind: .temporary, label: "Cabin",
            latitude: village.lat, longitude: village.lon, radiusKm: 25,
            locality: nil, isoCountryCode: nil, startedAt: date(day: 10), endedAt: nil)
        let classifier = await makeClassifier(container)
        await classifier.primeShapeForTesting(
            latitude: village.lat, longitude: village.lon,
            shape: .fallbackDisc(latitude: village.lat, longitude: village.lon))

        let preview = try #require(await classifier.previewTemporaryHomeChange(
            draft: draft, removing: false, pinnedTripIDs: []))
        #expect(!preview.areaIsCityBoundary)
        #expect(preview.staysJoining == 0)
        #expect(preview.firstStayInArea == nil)

        classifier.failReconciliationStayReadForTesting = true
        defer { classifier.failReconciliationStayReadForTesting = false }
        #expect(await classifier.previewTemporaryHomeChange(
            draft: draft, removing: false, pinnedTripIDs: []) == nil)
    }

    @Test("the preview reports the named time zone most stays in the proposed area carry, whatever the dates and whatever the newest stay says, the newest one's when two tie, and none when the stays there carry only a fixed offset or no zone, or when the temporary home is being removed")
    func previewReportsTheAreasNamedTimeZone() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        let older = makeStay(in: ctx, at: Self.brussels, startDay: 20, category: .destination)
        older.timeZoneIdentifier = "Europe/Paris"
        let named = makeStay(in: ctx, at: Self.brussels, startDay: 40, category: .destination)
        named.timeZoneIdentifier = "Europe/Brussels"
        // The last stay before a flight, clustered after landing: the next place's zone.
        let afterFlight = makeStay(in: ctx, at: Self.brussels, startDay: 55, category: .destination)
        afterFlight.timeZoneIdentifier = "Europe/Athens"
        // Newer, with a fixed offset approximated from the longitude, and with no zone.
        let approximated = makeStay(in: ctx, at: Self.brussels, startDay: 50, category: .destination)
        approximated.timeZoneIdentifier = "GMT+0100"
        _ = makeStay(in: ctx, at: Self.brussels, startDay: 60, category: .destination)
        // Newer and named, but not in the area.
        let elsewhere = makeStay(in: ctx, at: Self.athens, startDay: 70, category: .home)
        elsewhere.timeZoneIdentifier = "Europe/Athens"
        try ctx.save()
        let draft = HomeAnchor(
            id: UUID(), kind: .temporary, label: "Semester",
            latitude: Self.brussels.lat, longitude: Self.brussels.lon, radiusKm: 25,
            locality: nil, isoCountryCode: nil, startedAt: date(day: 30), endedAt: nil)

        let preview = try #require(await makeClassifier(container).previewTemporaryHomeChange(
            draft: draft, removing: false, pinnedTripIDs: []))
        // One stay each: the newest named one decides.
        #expect(preview.areaTimeZoneIdentifier == "Europe/Athens")
        // Two stays before the draft's start carry the place's zone: most stays decide.
        for day in [10.0, 15.0] {
            makeStay(in: ctx, at: Self.brussels, startDay: day, category: .destination)
                .timeZoneIdentifier = "Europe/Brussels"
        }
        try ctx.save()
        let most = try #require(await makeClassifier(container).previewTemporaryHomeChange(
            draft: draft, removing: false, pinnedTripIDs: []))
        #expect(most.areaTimeZoneIdentifier == "Europe/Brussels")
        let removal = try #require(await makeClassifier(container).previewTemporaryHomeChange(
            draft: draft, removing: true, pinnedTripIDs: []))
        #expect(removal.areaTimeZoneIdentifier == nil)

        let stays = try ctx.fetch(FetchDescriptor<Stay>())
        for stay in stays where stay.id != older.id { stay.timeZoneIdentifier = nil }
        older.timeZoneIdentifier = "GMT+0200"
        try ctx.save()
        let unnamed = try #require(await makeClassifier(container).previewTemporaryHomeChange(
            draft: draft, removing: false, pinnedTripIDs: []))
        #expect(unnamed.areaTimeZoneIdentifier == nil)
        #expect(unnamed.firstStayInArea == date(day: 10))
    }

    // MARK: - Entry point

    @Test("a temporary home with nothing to change settles through the gated entry point")
    func entryPointSettlesWhenNothingChanges() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        let semester = insertSemester(in: ctx)
        try ctx.save()

        let classifier = await makeClassifier(container)
        let log = TemporaryHomeSettleLog()
        let outcome = await classifier.applyTemporaryHomeChange(
            temporaryHomeID: semester.id, pinnedTripIDs: { [] },
            gate: PipelineGate(forTesting: ()),
            onSettled: { log.events.append("settled") })
        #expect(outcome == .committed(stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 0))
        #expect(outcome.isSettled)
        #expect(log.events == ["settled"])
    }

    @Test("a failed reconciliation through the gated entry point reports failure, does not settle and changes nothing")
    func entryPointReportsFailure() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        let semester = insertSemester(in: ctx)
        _ = seedSemesterTrip(in: ctx)
        try ctx.save()
        let before = try storeState(container)

        let classifier = await makeClassifier(container)
        await classifier.failNextReconciliationSaveForTesting()
        let log = TemporaryHomeSettleLog()
        let outcome = await classifier.applyTemporaryHomeChange(
            temporaryHomeID: semester.id, pinnedTripIDs: { [] },
            gate: PipelineGate(forTesting: ()),
            onSettled: { log.events.append("settled") })
        #expect(outcome == .failed)
        #expect(!outcome.isSettled)
        #expect(log.events.isEmpty)
        #expect(try storeState(container) == before)
    }

    @Test("a reconciliation cancelled while queued behind the pipeline reports cancellation and is not settled")
    func queuedReconciliationCancellation() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let classifier = TripClassifier(modelContainer: container)
        await classifier.setRunningLatchForTesting(true)
        let task = Task {
            await classifier.applyTemporaryHomeChange(
                temporaryHomeID: UUID(), pinnedTripIDs: { [] }, gate: PipelineGate(forTesting: ()))
        }
        task.cancel()
        let outcome = await task.value
        #expect(outcome == .cancelled)
        #expect(!outcome.isSettled)
        await classifier.setRunningLatchForTesting(false)
    }

    // MARK: - Waiting behind another writer

    /// A gate another writer is inside, until `release` is called.
    private func heldGate() async -> (gate: PipelineGate, release: () -> Void, writer: Task<Void, Never>) {
        let gate = PipelineGate(forTesting: ())
        let (entered, enteredSignal) = AsyncStream<Void>.makeStream()
        let (released, releaseSignal) = AsyncStream<Void>.makeStream()
        let writer = Task {
            await gate.run(touching: []) {
                enteredSignal.yield()
                for await _ in released { break }
            }
        }
        for await _ in entered { break }
        return (gate, { _ = releaseSignal.yield() }, writer)
    }

    @Test("a trip favorited while the reconciliation waits behind another writer is archived as a favorite when the covering splits it, and unpinned after the commit")
    func tripFavoritedWhileWaitingForTheGateIsArchivedAsAFavorite() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        let semesterID = insertSemester(in: ctx).id
        let fixture = seedSemesterTrip(in: ctx)
        try ctx.save()

        let classifier = await makeClassifier(container)
        let box = TemporaryHomeRecordBox()
        await classifier.setDissolvedRecordSink { box.append($0) }
        let held = await heldGate()
        let gate = held.gate
        let favorites = TemporaryHomeFavorites()
        let reconciliation = Task {
            await StayClassificationInference.TestHook.$availability.withValue(false) {
                await classifier.applyTemporaryHomeChange(
                    temporaryHomeID: semesterID,
                    pinnedTripIDs: { favorites.ids }, gate: gate,
                    unpinRetired: { favorites.ids.subtract($0) })
            }
        }
        // Let the call reach the gate first. The outcome does not depend on
        // it: the favorite always lands before the writer ahead lets go.
        for _ in 0..<2 { _ = await classifier.readFailureContextHasChangesForTesting() }
        favorites.ids = [fixture.tripID]
        held.release()
        let outcome = await reconciliation.value
        await held.writer.value

        // Split as it is with no favorite (`lateDeclarationSplitsCompletedTrip`),
        // with the favorite read inside the unit in its archive.
        #expect(outcome == .committed(stamped: 3, freed: 0, rebuiltTrips: 1, protectedTrips: 0))
        #expect(box.records.map(\.id) == [fixture.tripID])
        #expect(box.records.first?.wasFavourite == true)
        #expect(try stayIDsByTrip(container)[fixture.tripID] == nil)
        #expect(favorites.ids.isEmpty)
    }

    @Test("a reconciliation cancelled while it waits behind another writer reports cancellation, changes nothing and is not settled, and a later run completes it")
    func cancellationWhileWaitingForTheGate() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        let semesterID = insertSemester(in: ctx).id
        _ = seedSemesterTrip(in: ctx)
        try ctx.save()
        let before = try storeState(container)

        let classifier = await makeClassifier(container)
        let held = await heldGate()
        let gate = held.gate
        let log = TemporaryHomeSettleLog()
        let reconciliation = Task {
            // Pinned off: a run that wrongly committed would go on to the pipeline.
            await StayClassificationInference.TestHook.$availability.withValue(false) {
                await classifier.applyTemporaryHomeChange(
                    temporaryHomeID: semesterID, pinnedTripIDs: { [] }, gate: gate,
                    onSettled: { log.events.append("settled") })
            }
        }
        // Let the call reach the gate first. The outcome does not depend on
        // it: the cancellation always lands before the writer ahead lets go.
        for _ in 0..<2 { _ = await classifier.readFailureContextHasChangesForTesting() }
        reconciliation.cancel()
        held.release()
        let outcome = await reconciliation.value
        await held.writer.value

        #expect(outcome == .cancelled)
        #expect(!outcome.isSettled)
        #expect(log.events.isEmpty)
        #expect(try storeState(container) == before)
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)

        // Not vacuous: the same change, run to the end, rewrites this store.
        #expect(await classifier.applyTemporaryHomeChangeCore(
            temporaryHomeID: semesterID, pinnedTripIDs: [])
            == .committed(stamped: 3, freed: 0, rebuiltTrips: 1, protectedTrips: 0))
        #expect(try storeState(container) != before)
    }
}

// MARK: - What the stays reflect when an edit outruns its reconciliation

extension TemporaryHomeReconciliationTests {
    private func villagePayload(
        _ target: TemporaryHomeSavePayload.Target, from: Double = 10
    ) -> TemporaryHomeSavePayload {
        TemporaryHomeSavePayload(
            target: target, label: "Semester",
            latitude: Self.village.lat, longitude: Self.village.lon,
            locality: nil, administrativeArea: nil, country: nil, isoCountryCode: nil,
            startedAt: date(day: from), endedAt: date(day: 100),
            timeZoneIdentifier: "GMT", now: date(day: 120))
    }

    @Test("a unit killed after its commit, then a replay that fails, then a removal: the stay the killed unit made home records it, so the removal frees it")
    func failedReplayKeepsTheMarkOfAnInterruptedUnit() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        let id = insertSemester(in: ctx).id
        let visitID = makeStay(in: ctx, at: Self.village, startDay: 20, category: .destination).id
        try ctx.save()

        // The pin moves from Brussels to the village; its unit commits and
        // the app is killed before the debt settles.
        _ = TemporaryHomeSaveWorker.apply(
            villagePayload(.edit(id)), context: ModelContext(container), pendingDefaults: defaults)
        #expect(await makeClassifierWithVillage(container).applyTemporaryHomeChangeCore(
            temporaryHomeID: id, pinnedTripIDs: [])
            == .committed(stamped: 1, freed: 0, rebuiltTrips: 0, protectedTrips: 0))
        #expect(try stay(visitID, container).temporaryHomeID == id)

        // The next launch replays it, and a required read fails.
        let replay = await makeClassifierWithVillage(container)
        replay.failReconciliationStayReadForTesting = true
        #expect(await replay.applyTemporaryHomeChange(
            temporaryHomeID: id, pinnedTripIDs: { [] },
            gate: PipelineGate(forTesting: ())) == .failed)

        // Removed before a replay succeeds.
        _ = TemporaryHomeSaveWorker.apply(
            .removing(id, now: date(day: 121)), context: ModelContext(container),
            pendingDefaults: defaults)
        #expect(await reconcile(await makeClassifierWithVillage(container), id)
                == .committed(stamped: 0, freed: 1, rebuiltTrips: 0, protectedTrips: 0))
        #expect(try stay(visitID, container).category == .unclassified)
    }

    @Test("while a first edit is still owed, the preview of a second edit counts what its unit then frees: a start moved earlier and back frees none of the older home stays at the spot")
    func previewOfASecondEditMatchesItsUnitWhileTheFirstIsOwed() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let fixture = seedVillage(in: ctx)
        try ctx.save()

        // The start moves to day 1: saved, not reconciled. Then back to day 10.
        _ = TemporaryHomeSaveWorker.apply(
            villagePayload(.edit(fixture.id), from: 1), context: ModelContext(container),
            pendingDefaults: defaults)
        let stored = try #require(try HomeAnchors.temporaryHomes(in: ModelContext(container)).first)
        let draft = HomeAnchor(
            id: stored.id, kind: .temporary, label: stored.label,
            latitude: stored.latitude, longitude: stored.longitude, radiusKm: stored.radiusKm,
            locality: nil, isoCountryCode: nil, startedAt: date(day: 10), endedAt: date(day: 100))
        let preview = try #require(await makeClassifierWithVillage(container)
            .previewTemporaryHomeChange(draft: draft, removing: false, pinnedTripIDs: []))
        _ = TemporaryHomeSaveWorker.apply(
            villagePayload(.edit(fixture.id)), context: ModelContext(container),
            pendingDefaults: defaults)

        #expect(preview.staysLeaving == 0)
        #expect(await reconcile(await makeClassifierWithVillage(container), fixture.id)
                == .committed(stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 0))
        try expectHome(fixture.legacy, container)
    }
}

// MARK: - Stored names

extension TemporaryHomeReconciliationTests {

    /// On the edge of Brussels and named for it, outside the square the
    /// classifier is primed with: no unit stamps it home.
    private static let brusselsEdge = (lat: 50.7504, lon: 4.3158)
    private static let vienna = (lat: 48.2545, lon: 16.3599)

    /// A destination named `name`, as the geocoder's metro gives it.
    private func placeStay(
        in ctx: ModelContext, _ name: String,
        // `ieper`: a default argument cannot read the main-actor static.
        at place: (lat: Double, lon: Double) = (lat: 51.85, lon: 4.35),
        day: Double, hours: Double = 3
    ) -> Stay {
        let stay = makeStay(in: ctx, at: place, startDay: day, days: hours / 24, category: .destination)
        stay.metroName = name
        return stay
    }

    /// A semester at Brussels from day 10 to day 20 with a home stay it made
    /// on day 15, and a completed weekend away on days 30 and 31, a few hours
    /// on the edge of Brussels and a few in `away`. Its names were stored
    /// while the semester ended on day 20, as a V19 date edit left them.
    private func seedWeekendAway(
        in ctx: ModelContext, brusselsHours: Double = 3, awayHours: Double = 3,
        away: String = "Beringen", awayIsLocality: Bool = false, title: String? = "Brussels & Beringen"
    ) throws -> (semesterID: UUID, trip: Trip) {
        seedRealHome(in: ctx)
        let semester = insertSemester(in: ctx, from: 10, until: 20)
        semester.locality = "Brussels"
        _ = makeStay(in: ctx, at: Self.brussels, startDay: 15, category: .home, stampedBy: semester.id)
        let edge = placeStay(in: ctx, "Brussels", at: Self.brusselsEdge, day: 30, hours: brusselsHours)
        let far = placeStay(in: ctx, away, day: 31, hours: awayHours)
        if awayIsLocality {
            far.metroName = nil
            far.locality = away
        }
        let trip = makeTrip(in: ctx, [edge, far], complete: true)
        trip.aiGeneratedTitle = title
        try ctx.save()
        TripTitleStore.invalidateHomePlaceIndex()
        #expect(trip.recomputeSummary())
        try ctx.save()
        return (semester.id, trip)
    }

    /// Saves new dates on every row of a temporary home.
    private func setDates(
        _ id: UUID, from: Double = 10, until: Double?, _ container: ModelContainer
    ) throws {
        let ctx = ModelContext(container)
        for row in try ctx.fetch(FetchDescriptor<TemporaryHome>()) where row.id == id {
            row.startedAt = date(day: from)
            row.endedAt = until.map { date(day: $0) }
        }
        try ctx.save()
    }

    /// Every field of a trip that names it, as committed.
    private struct StoredNames: Equatable {
        let summary: String
        let countryCodes: String
        let source: String
        let customName: String?
        let title: String?
        let revision: UUID?
        let narrative: String?
        let narrativeDate: Date?
        let variants: Set<String>
    }

    private func storedNames(_ container: ModelContainer) throws -> [UUID: StoredNames] {
        var result: [UUID: StoredNames] = [:]
        for trip in try ModelContext(container).fetch(FetchDescriptor<Trip>()) {
            result[trip.id] = StoredNames(
                summary: trip.destinationSummary, countryCodes: trip.countryCodes,
                source: trip.sourceRaw, customName: trip.customName,
                title: trip.aiGeneratedTitle, revision: trip.titleSourceRevision,
                narrative: trip.aiGeneratedSummary, narrativeDate: trip.summaryGeneratedAt,
                variants: Set((trip.localizedTitles ?? []).map {
                    "\($0.id) \($0.languageTag) \($0.title)"
                }))
        }
        return result
    }

    /// Every trip's stored summary is what a fresh recompute gives, and every
    /// stored title passes the title policy for the inputs as committed.
    private func expectNamesAreCurrent(
        _ container: ModelContainer, _ classifier: TripClassifier
    ) throws {
        TripTitleStore.invalidateHomePlaceIndex()
        let ctx = ModelContext(container)
        for trip in try ctx.fetch(FetchDescriptor<Trip>()) {
            let stored = trip.destinationSummary
            #expect(trip.recomputeSummary())
            #expect(trip.destinationSummary == stored,
                    "stored \(stored), fresh \(trip.destinationSummary)")
            if let title = trip.aiGeneratedTitle {
                let homes = try TripClassifier.homePlaceNames(for: trip, in: ctx)
                #expect(classifier.titleValidationFailure(title, for: trip, homePlaceNames: homes) == nil,
                        "\(title)")
            }
        }
    }

    private static let nothingMoved = TripClassifier.TemporaryHomeReconciliationOutcome.committed(
        stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 0)

    @Test("extending the dates over a trip refreshes its summary although no stay moves, and clears the title that names the base, so the trip shows the summary")
    func dateEditRefreshesTheSummaryAndTitleOfAnUntouchedTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let (semesterID, journey) = try seedWeekendAway(in: ctx)
        #expect(journey.destinationSummary == "Brussels, Beringen")

        try setDates(semesterID, until: 100, container)
        let classifier = await makeClassifier(container)
        #expect(await reconcile(classifier, semesterID) == Self.nothingMoved)

        let stored = try trip(journey.id, container)
        #expect(stored.destinationSummary == "Beringen")
        #expect(stored.aiGeneratedTitle == nil)
        #expect(stored.titleSourceRevision == nil)
        #expect(stored.displayName == "Beringen")
        try expectNamesAreCurrent(container, classifier)
    }

    @Test("after an end, a pin move, an earlier end and a removal, every trip's stored summary is what a fresh recompute gives and every title passes the policy, and a trip none of them reach keeps every name field")
    func everyTripsSummaryEqualsAFreshRecomputeAfterEachChange() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        let semester = insertSemester(in: ctx, from: 10, until: 100)
        semester.locality = "Brussels"
        let id = semester.id
        _ = makeStay(in: ctx, at: Self.brussels, startDay: 15, category: .home, stampedBy: id)
        // Named and titled before the semester was declared.
        func away(_ names: [String], day: Double, title: String?) -> Trip {
            let stays = names.enumerated().map { index, name in
                placeStay(in: ctx, name, at: name == "Brussels" ? Self.brusselsEdge : Self.ieper,
                          day: day + Double(index) * 0.5, hours: 9)
            }
            let trip = makeTrip(in: ctx, stays, complete: true)
            trip.destinationSummary = names.joined(separator: ", ")
            trip.aiGeneratedTitle = title
            return trip
        }
        let beringenID = away(["Brussels", "Beringen"], day: 30, title: "Brussels & Beringen").id
        let ieperID = away(["Brussels", "Ieper"], day: 120, title: "Brussels & Ieper").id
        let errandID = away(["Brussels"], day: 50, title: "Brussels").id
        let renamed = away(["Brussels", "Knokke-Heist"], day: 60, title: "Brussels & Knokke-Heist")
        renamed.customName = "Flat hunting"
        let favoriteID = away(["Beringen", "Brussels"], day: 70, title: "Beringen & Brussels").id
        let vienna = makeTrip(in: ctx, [
            placeStay(in: ctx, "Vienna", at: Self.vienna, day: 400, hours: 20),
            placeStay(in: ctx, "Vienna", at: Self.vienna, day: 401, hours: 20),
        ], complete: true)
        try ctx.save()
        TripTitleStore.invalidateHomePlaceIndex()
        #expect(vienna.recomputeSummary())
        vienna.aiGeneratedTitle = "Vienna"
        #expect(TripTitleStore.upsertVariant(
            languageTag: "fr", title: "Vienne", sourceTitle: "Vienna", for: vienna, in: ctx))
        vienna.aiGeneratedSummary = "Two days in Vienna."
        vienna.summaryGeneratedAt = date(day: 403)
        try ctx.save()
        let viennaNames = try #require(try storedNames(container)[vienna.id])
        #expect(viennaNames.summary == "Vienna")

        func run(_ payload: TemporaryHomeSavePayload) async throws {
            #expect(!TemporaryHomeSaveWorker.apply(
                payload, context: ModelContext(container), pendingDefaults: defaults).failed)
            let classifier = await makeClassifier(container)
            await classifier.primeShapeForTesting(
                latitude: Self.vienna.lat, longitude: Self.vienna.lon,
                shape: TemporaryHomeFixture.squareShape(id: 3, around: Self.vienna))
            #expect(await reconcile(classifier, id, pinned: [favoriteID]).isSettled)
            try expectNamesAreCurrent(container, classifier)
            #expect(try storedNames(container)[vienna.id] == viennaNames)
        }

        // Ended on day 150: the later weekend is inside it now.
        try await run(.ending(id, on: date(day: 150), now: date(day: 140)))
        let names = try storedNames(container)
        #expect(names[beringenID]?.summary == "Beringen")
        #expect(names[beringenID]?.title == nil)
        #expect(names[ieperID]?.summary == "Ieper")
        #expect(names[ieperID]?.title == nil)
        // Its whole time was at the base, so the base still names it.
        #expect(names[errandID]?.summary == "Brussels")
        #expect(names[errandID]?.title == "Brussels")
        #expect(names[renamed.id]?.summary == "Knokke-Heist")
        #expect(names[renamed.id]?.title == nil)
        #expect(names[renamed.id]?.customName == "Flat hunting")
        #expect(names[favoriteID]?.summary == "Beringen")
        #expect(names[favoriteID]?.title == nil)

        // The pin moves to Vienna for the same dates, freeing the stay it made at Brussels.
        try await run(TemporaryHomeSavePayload(
            target: .edit(id), label: "Semester",
            latitude: Self.vienna.lat, longitude: Self.vienna.lon,
            locality: "Vienna", administrativeArea: nil, country: "Austria",
            isoCountryCode: "AT", startedAt: date(day: 10), endedAt: date(day: 150),
            timeZoneIdentifier: "GMT", now: date(day: 141)))
        #expect(try storedNames(container)[beringenID]?.summary == "Brussels, Beringen")

        // Ended earlier, on day 90, then removed.
        try await run(.ending(id, on: date(day: 90), now: date(day: 142)))
        try await run(.removing(id, now: date(day: 143)))
        #expect(try storedNames(container)[renamed.id]?.customName == "Flat hunting")
    }

    @Test("a date edit that takes a short stop named like the base out of the summary keeps the title the policy still accepts, its revision and its translation")
    func aTitleTheValidatorAcceptsIsKept() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let (semesterID, journey) = try seedWeekendAway(
            in: ctx, brusselsHours: 1, awayHours: 10, title: "Beringen")
        #expect(TripTitleStore.upsertVariant(
            languageTag: "fr", title: "Beringen en voyage", sourceTitle: "Beringen", for: journey, in: ctx))
        try ctx.save()
        let before = try #require(try storedNames(container)[journey.id])
        #expect(before.summary == "Brussels, Beringen")
        #expect(before.revision != nil)
        #expect(before.variants.count == 1)

        try setDates(semesterID, until: 100, container)
        #expect(await reconcile(await makeClassifier(container), semesterID) == Self.nothingMoved)

        let after = try #require(try storedNames(container)[journey.id])
        #expect(after.summary == "Beringen")
        #expect(after.title == "Beringen")
        #expect(after.revision == before.revision)
        #expect(after.variants == before.variants)
        #expect(try trip(journey.id, container).displayName(languageTag: "fr") == "Beringen en voyage")
    }

    @Test("a place whose name holds a comma is refreshed like any other once its trip is complete")
    func commaNameRefreshesACompleteTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let (semesterID, journey) = try seedWeekendAway(
            in: ctx, brusselsHours: 1, awayHours: 10,
            away: "Washington, D.C.", awayIsLocality: true, title: nil)
        #expect(journey.destinationSummary == "Brussels, Washington, D.C.")

        try setDates(semesterID, until: 100, container)
        let classifier = await makeClassifier(container)
        #expect(await reconcile(classifier, semesterID) == Self.nothingMoved)
        #expect(try trip(journey.id, container).destinationSummary == "Washington, D.C.")
        try expectNamesAreCurrent(container, classifier)
    }

    @Test("a trip whose stored summary names a place none of its stays give, its other stays still on their way, keeps its summary and its title")
    func anIncompleteTripIsSkippedWhole() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let (semesterID, journey) = try seedWeekendAway(in: ctx)
        journey.destinationSummary = "Brussels, Beringen, Sint-Amandsberg"
        try ctx.save()
        let before = try #require(try storedNames(container)[journey.id])

        try setDates(semesterID, until: 100, container)
        #expect(await reconcile(await makeClassifier(container), semesterID) == Self.nothingMoved)
        #expect(try storedNames(container)[journey.id] == before)
    }

    // The completeness guard read only destinations, so
    // a member the unit itself settled as transit looked like a missing one.
    @Test("a trip the user kept whose airport stop at the base the unit settles as transit is complete, not partly arrived: its summary drops the base and the title naming it is cleared")
    func settlingATransitMemberRefreshesItsCompleteTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedRealHome(in: ctx)
        let semester = insertSemester(in: ctx, from: 10, until: 100)
        semester.locality = "Brussels"
        let semesterID = semester.id
        // Stamped home by the pre-filter while still linked.
        let airport = makeStay(in: ctx, at: Self.brussels, startDay: 30.5, days: 1.0 / 24,
                               category: .home, stampedBy: semesterID)
        airport.isAirport = true
        airport.metroName = "Brussels"
        let journey = makeTrip(in: ctx, [
            airport, placeStay(in: ctx, "Paris", at: Self.paris, day: 31, hours: 12),
        ], complete: true)
        journey.userEdited = true
        journey.keptByTemporaryHome = true
        semester.addKeptTrip(journey.id)
        journey.destinationSummary = "Brussels, Paris"
        journey.aiGeneratedTitle = "Brussels & Paris"
        try ctx.save()
        let journeyID = journey.id

        let classifier = await makeClassifier(container)
        #expect(await reconcile(classifier, semesterID)
                == .committed(stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 1))
        let settled = try stay(airport.id, container)
        #expect(settled.category == .transit)
        #expect(settled.trip?.id == journeyID)
        let after = try trip(journeyID, container)
        #expect(after.destinationSummary == "Paris")
        #expect(after.aiGeneratedTitle == nil)
        try expectNamesAreCurrent(container, classifier)
    }

    @Test("with no stay to move, the refreshed names commit in the unit's one save: a failed save leaves them as they were and the retry writes them")
    func noStayMovesStillRefreshesAndCommitsOnce() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let (semesterID, journey) = try seedWeekendAway(in: ctx)
        let before = try storedNames(container)
        try setDates(semesterID, until: 100, container)

        let classifier = await makeClassifier(container)
        await classifier.failNextReconciliationSaveForTesting()
        #expect(await reconcile(classifier, semesterID) == .failed)
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        #expect(try storedNames(container) == before)

        #expect(await reconcile(classifier, semesterID) == Self.nothingMoved)
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        let stored = try trip(journey.id, container)
        #expect(stored.destinationSummary == "Beringen")
        #expect(stored.aiGeneratedTitle == nil)
    }

    @Test("a replay of a unit that refreshed names writes nothing")
    func aReplayChangesNothing() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let (semesterID, _) = try seedWeekendAway(in: ctx)
        try setDates(semesterID, until: 100, container)
        #expect(await reconcile(await makeClassifier(container), semesterID) == Self.nothingMoved)
        let settled = try storedNames(container)

        let replay = await makeClassifier(container)
        // A replay that had anything to write would fail here.
        await replay.failNextReconciliationSaveForTesting()
        #expect(await reconcile(replay, semesterID) == Self.nothingMoved)
        #expect(await replay.readFailureContextHasChangesForTesting() == false)
        #expect(try storedNames(container) == settled)
    }

    @Test("home places that cannot be read fail the unit whole: the withdrawn correction and the names stay as they were, and a retry commits both")
    func unreadableHomePlacesFailTheUnitWhole() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let (semesterID, journey) = try seedWeekendAway(in: ctx)
        // An earlier temporary home, removed, left a correction for the unit to withdraw.
        let earlier = TemporaryHome(
            label: "Earlier", latitude: Self.ieper.lat, longitude: Self.ieper.lon,
            startedAt: date(day: -300), endedAt: date(day: -200))
        ctx.insert(earlier)
        ctx.insert(HomeAreaOverride(
            kind: .exclude, centerLatitude: Self.ieper.lat, centerLongitude: Self.ieper.lon,
            radiusKm: 2, homeID: earlier.id))
        try ctx.save()
        try markRemoved(earlier.id, in: ctx)
        let before = try storedNames(container)
        try setDates(semesterID, until: 100, container)
        func corrections() throws -> Int {
            try ModelContext(container).fetchCount(FetchDescriptor<HomeAreaOverride>())
        }

        let classifier = await makeClassifier(container)
        let failed = await TripTitleStore.HomePlaceIndex.$failFetchForTesting.withValue(true) {
            await classifier.applyTemporaryHomeChangeCore(
                temporaryHomeID: semesterID, pinnedTripIDs: [])
        }
        #expect(failed == .failed)
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        #expect(try corrections() == 1)
        #expect(try storedNames(container) == before)

        #expect(await reconcile(classifier, semesterID) == Self.nothingMoved)
        #expect(try corrections() == 0)
        #expect(try trip(journey.id, container).destinationSummary == "Beringen")
    }

    @Test("the debt of an add whose row never saved changes no name anywhere and runs no title stage")
    func anOrphanAddDebtChangesNothing() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let home = Home(label: "Athens", latitude: Self.athens.lat, longitude: Self.athens.lon,
                        radiusKm: 25, startedAt: date(day: -1000))
        home.locality = "Athens"
        ctx.insert(home)
        _ = makeStay(in: ctx, at: Self.athens, startDay: 0, category: .home)
        // Named before the home's locality was known: a fresh recompute leaves Athens out.
        let stale = makeTrip(in: ctx, [
            placeStay(in: ctx, "Athens", at: Self.village, day: 30, hours: 2),
            placeStay(in: ctx, "Paris", day: 31, hours: 9),
        ], complete: true)
        stale.destinationSummary = "Athens, Paris"
        let untitled = makeTrip(in: ctx, [placeStay(in: ctx, "Alès", day: 60, hours: 9)], complete: true)
        untitled.destinationSummary = "Alès"
        try ctx.save()
        let before = try storedNames(container)

        let classifier = await makeClassifier(container)
        let log = TemporaryHomeSettleLog()
        await classifier.setTitleGenerationOverrideForTesting { _ in
            await MainActor.run { log.events.append("title") }
            return "Alès"
        }
        #expect(await classifier.applyTemporaryHomeChange(
            temporaryHomeID: UUID(), pinnedTripIDs: { [] },
            gate: PipelineGate(forTesting: ())) == Self.nothingMoved)
        #expect(try storedNames(container) == before)
        #expect(log.events.isEmpty)
        await classifier.setTitleGenerationOverrideForTesting(nil)
    }

    // The wrapper's invariant check ran
    // the pipeline for an orphan debt in a store that never had a temporary home.
    @Test("the debt of an add whose row never saved, in a store that never had a temporary home, assembles no trip from a tripless destination it finds")
    func anOrphanAddDebtAssemblesNothing() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        ctx.insert(Home(label: "Athens", latitude: Self.athens.lat, longitude: Self.athens.lon,
                        radiusKm: 25, startedAt: date(day: -1000)))
        _ = makeStay(in: ctx, at: Self.athens, startDay: 0, days: 9.5, category: .home)
        let paris = makeStay(in: ctx, at: Self.paris, startDay: 10, days: 2, category: .destination)
        _ = makeStay(in: ctx, at: Self.athens, startDay: 12.5, days: 3, category: .home)
        try ctx.save()
        let before = try storeState(container)
        #expect(before.tripIDs.isEmpty)

        let classifier = await makeClassifier(container)
        let outcome = await StayClassificationInference.TestHook.$availability.withValue(false) {
            await classifier.applyTemporaryHomeChange(
                temporaryHomeID: UUID(), pinnedTripIDs: { [] },
                gate: PipelineGate(forTesting: ()))
        }
        #expect(outcome == Self.nothingMoved)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Trip>()) == 0)
        #expect(try storeState(container) == before)
        let loose = try stay(paris.id, container)
        #expect(loose.category == .destination)
        #expect(loose.trip == nil)
    }

    @Test("a fallback title cleared by an edit returns when the edit is reverted to the inputs whose title budget is spent, without a model attempt")
    func exhaustedFallbackReturnsAfterEditRevert() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // The fallback a spent budget wrote for the weekend as it was.
        let (semesterID, journey) = try seedWeekendAway(in: ctx)
        let classifier = await makeClassifier(container)
        let spent = try #require(await classifier.canonicalTitleShapeForTesting(tripID: journey.id))
        await classifier.markCanonicalTitleFailureForTesting(spent)

        // Extended over the weekend while no model is at hand: the title names the base and goes.
        try setDates(semesterID, until: 100, container)
        #expect(await reconcile(classifier, semesterID) == Self.nothingMoved)
        #expect(try trip(journey.id, container).aiGeneratedTitle == nil)

        // Reverted: the weekend is back at the inputs whose budget is spent.
        try setDates(semesterID, until: 20, container)
        let replay = await makeClassifier(container)
        let log = TemporaryHomeSettleLog()
        await replay.setTitleGenerationOverrideForTesting { _ in
            await MainActor.run { log.events.append("model") }
            return nil
        }
        #expect(await replay.applyTemporaryHomeChange(
            temporaryHomeID: semesterID, pinnedTripIDs: { [] },
            gate: PipelineGate(forTesting: ())) == Self.nothingMoved)
        let restored = try trip(journey.id, container)
        #expect(restored.destinationSummary == "Brussels, Beringen")
        #expect(restored.aiGeneratedTitle == "Brussels & Beringen")
        #expect(log.events.isEmpty)
        await replay.setTitleGenerationOverrideForTesting(nil)
    }
}
