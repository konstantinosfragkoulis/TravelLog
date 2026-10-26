//
//  TripBoundaryHardeningTests.swift
//  TravelLogTests
//
//  Duplicate ongoing-trip regression: two independent mechanisms
//  minted a second trip mid-journey with no homecoming:
//
//  1. A `userEdited` ongoing trip is exempt from the detach pass (its stays
//     are sacred), so newly clustered stays had NOTHING to attach to and
//     were minted into a brand-new second ongoing trip. Fixed by the
//     adoption pass: home-free stays arriving AFTER a userEdited
//     open trip's last stay are appended to it instead of regrouped.
//
//  2. `preFilterStays` stamps `.home` with no dwell requirement, so a
//     single confidently-wrong live-SLC fix inside the home ring became a
//     zero-dwell `.home` stay; and `hasHomeStayBetween` / `closeTrip` /
//     `closeStaleOpenTrips` treated it as a genuine homecoming, splitting
//     the ongoing trip in two. Fixed by the qualifying-home-boundary rule:
//     live-SLC home stays need ≥15 min dwell to act as a boundary;
//     imported stays (photo/timeline/GPX) always qualify; a lone photo at
//     home IS historical evidence, not a live glitch.
//
//  Pattern (same as OngoingTripReuseTests): seed the "previous run's"
//  state by hand via a plain context + save, then read results ONLY
//  through the actor's seams; assembleTrips doesn't save, so a fresh
//  ModelContext can't see its in-context changes.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor @Suite(IsolatedLineageDefaults())
struct TripBoundaryHardeningTests {

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
        hex: String,
        source: DataSource = .liveSLC
    ) -> Stay {
        let start = date(day: startDay)
        let stay = Stay(
            startTime: start,
            endTime: start.addingTimeInterval(durationHours * 3600),
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
        stay.sourceRaw = source.rawValue
        ctx.insert(stay)
        return stay
    }

    /// Hand-builds "the previous pipeline run's" open trip holding `stays`.
    @discardableResult
    private func makeOpenTrip(
        in ctx: ModelContext,
        stays: [Stay],
        startDay: Double,
        userEdited: Bool = false
    ) -> Trip {
        let trip = Trip(startDate: date(day: startDay))
        trip.userEdited = userEdited
        ctx.insert(trip)
        for (order, stay) in stays.enumerated() {
            stay.trip = trip
            stay.orderInTrip = order
        }
        return trip
    }

    // MARK: - userEdited ongoing trip adopts new stays

    @Test("a userEdited ongoing trip adopts a new home-free stay instead of spawning a second trip")
    func userEditedOngoingTripAdoptsNewStay() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let s0 = makeStay(in: ctx, startDay: 0, category: .destination, hex: "A")
        let edited = makeOpenTrip(in: ctx, stays: [s0], startDay: 0, userEdited: true)
        // CloudKit can deliver a derivative before its canonical row. Even in
        // that transient state, a membership change must delete the derivative
        // rather than letting it resurrect a title for the old stay set.
        ctx.insert(TripTitleVariant(
            languageTag: "de",
            title: "Alter Titel",
            sourceTitle: "Old Title",
            trip: edited))
        // Mid-trip: the user renamed the trip (userEdited), then moved.
        // a NEW unassigned stay arrives with no home stay in between.
        let s1 = makeStay(in: ctx, startDay: 1, category: .destination, hex: "B")
        try ctx.save()

        _ = await classifier.assembleTrips()

        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.count == 1)
        #expect(trips.first?.id == edited.id)
        #expect(trips.first?.isComplete == false)
        let members = await classifier.tripStayIDsForTesting(edited.id)
        #expect(members == Set([s0.id, s1.id]))
        #expect(await classifier.aiTitleFieldsForTesting(edited.id)?.localizedCount == 0)
    }

    @Test("adoption appends in order after the trip's existing stays")
    func adoptionAssignsSequentialOrder() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let s0 = makeStay(in: ctx, startDay: 0, category: .destination, hex: "A")
        let s1 = makeStay(in: ctx, startDay: 1, category: .transit, hex: "B")
        let edited = makeOpenTrip(in: ctx, stays: [s0, s1], startDay: 0, userEdited: true)
        makeStay(in: ctx, startDay: 2, category: .destination, hex: "C")
        makeStay(in: ctx, startDay: 3, category: .destination, hex: "D")
        try ctx.save()

        _ = await classifier.assembleTrips()

        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.count == 1)
        #expect(trips.first?.id == edited.id)
        let orders0123: [Int?] = [0, 1, 2, 3]
        #expect(trips.first?.orders == orders0123)
    }

    @Test("a genuine homecoming still ends adoption; post-home stays form a new trip")
    func homecomingStillBoundsAdoption() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let s0 = makeStay(in: ctx, startDay: 0, category: .destination, hex: "A")
        let edited = makeOpenTrip(in: ctx, stays: [s0], startDay: 0, userEdited: true)
        // Real, qualifying homecoming (6 h dwell) …
        makeStay(in: ctx, startDay: 1, category: .home, hex: "H")
        // … then the user leaves again: this stay belongs to a NEW trip.
        let s2 = makeStay(in: ctx, startDay: 2, category: .destination, hex: "B")
        try ctx.save()

        _ = await classifier.assembleTrips()

        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.count == 2)
        let members = await classifier.tripStayIDsForTesting(edited.id)
        #expect(members == Set([s0.id]))
        let newTrip = trips.first { $0.id != edited.id }
        #expect(newTrip?.isComplete == false)
        #expect(newTrip.map { $0.startDate == date(day: 2) } == true)
        _ = s2
    }

    @Test("an already-split pair self-heals: the orphan second trip's stays fold back into the userEdited original")
    func existingSplitSelfHeals() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // Hand-built state: the userEdited original and the
        // spurious non-userEdited second trip.
        let s0 = makeStay(in: ctx, startDay: 0, category: .destination, hex: "A")
        let edited = makeOpenTrip(in: ctx, stays: [s0], startDay: 0, userEdited: true)
        let s1 = makeStay(in: ctx, startDay: 1, category: .destination, hex: "B")
        makeOpenTrip(in: ctx, stays: [s1], startDay: 1, userEdited: false)
        try ctx.save()

        _ = await classifier.assembleTrips()

        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.count == 1)
        #expect(trips.first?.id == edited.id)
        let members = await classifier.tripStayIDsForTesting(edited.id)
        #expect(members == Set([s0.id, s1.id]))
    }

    @Test("no userEdited open trip → adoption is a strict no-op (existing semantics untouched)")
    func adoptionNoOpWithoutUserEditedTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let s0 = makeStay(in: ctx, startDay: 0, category: .destination, hex: "A")
        let open = makeOpenTrip(in: ctx, stays: [s0], startDay: 0, userEdited: false)
        makeStay(in: ctx, startDay: 1, category: .destination, hex: "B")
        try ctx.save()

        _ = await classifier.assembleTrips()

        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.count == 1)
        #expect(trips.first?.id == open.id) // normal reuse path, not adoption
        let orders01: [Int?] = [0, 1]
        #expect(trips.first?.orders == orders01)
    }

    // MARK: - Qualifying home boundary (phantom-fix guard)

    @Test("a zero-dwell live-SLC home stay is NOT a trip boundary; the trip neither splits nor closes")
    func phantomHomeStayDoesNotSplitOrClose() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        makeStay(in: ctx, startDay: 0, category: .destination, hex: "A")
        // The phantom: one misrouted SLC fix inside the home ring,
        // a single-ping, zero-dwell `.home` stay mid-trip.
        makeStay(in: ctx, startDay: 0.5, durationHours: 0, category: .home, hex: "H")
        makeStay(in: ctx, startDay: 1, category: .destination, hex: "B")
        try ctx.save()

        _ = await classifier.assembleTrips()

        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.count == 1)
        #expect(trips.first?.isComplete == false) // no qualifying home after → still ongoing
        let orders01: [Int?] = [0, 1]
        #expect(trips.first?.orders == orders01)
    }

    @Test("a trip spanning a zero-dwell live-SLC home closes only on the later qualifying home")
    func phantomHomeThenQualifyingHomeClosesOnce() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        makeStay(in: ctx, startDay: 0, category: .destination, hex: "A")
        makeStay(in: ctx, startDay: 0.5, durationHours: 0, category: .home, hex: "H")
        makeStay(in: ctx, startDay: 1, category: .destination, hex: "B")
        makeStay(in: ctx, startDay: 2, durationHours: 6, category: .home, hex: "H")
        try ctx.save()

        _ = await classifier.assembleTrips()

        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.count == 1)
        #expect(trips.first?.isComplete == true)
        let orders01: [Int?] = [0, 1]
        #expect(trips.first?.orders == orders01)
    }

    @Test("a qualifying live-SLC home stay (≥15 min dwell) still splits and closes; real homecomings are untouched")
    func qualifyingHomeStayStillSplits() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        makeStay(in: ctx, startDay: 0, category: .destination, hex: "A")
        makeStay(in: ctx, startDay: 0.5, durationHours: 6, category: .home, hex: "H")
        makeStay(in: ctx, startDay: 1, category: .destination, hex: "B")
        try ctx.save()

        _ = await classifier.assembleTrips()

        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.count == 2)
        #expect(trips.first?.isComplete == true) // closed by the genuine homecoming
        #expect(trips.last?.isComplete == false)
    }

    @Test("a zero-dwell photo-import home stay still splits; imported evidence always qualifies")
    func importedHomeStayAlwaysQualifies() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        makeStay(in: ctx, startDay: 0, category: .destination, hex: "A")
        makeStay(in: ctx, startDay: 0.5, durationHours: 0, category: .home, hex: "H", source: .photoImport)
        makeStay(in: ctx, startDay: 1, category: .destination, hex: "B")
        try ctx.save()

        _ = await classifier.assembleTrips()

        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.count == 2)
    }

    @Test("closeStaleOpenTrips ignores a phantom home stay but closes on a qualifying one")
    func closeStaleOpenTripsRequiresQualifyingHome() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let s0 = makeStay(in: ctx, startDay: 0, category: .destination, hex: "A")
        makeOpenTrip(in: ctx, stays: [s0], startDay: 0)
        makeStay(in: ctx, startDay: 1, durationHours: 0, category: .home, hex: "H")
        try ctx.save()

        let closedByPhantom = await classifier.closeStaleOpenTrips()
        #expect(closedByPhantom == 0)

        makeStay(in: ctx, startDay: 2, durationHours: 6, category: .home, hex: "H")
        try ctx.save()

        let closedByReal = await classifier.closeStaleOpenTrips()
        #expect(closedByReal == 1)
    }

    @Test("closeStaleOpenTrips closes exactly the trips the start-sorted home read closed")
    func closeStaleOpenTripsMatchesSortedRead() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // Closes on a qualifying home starting exactly at its last stay's end.
        let a0 = makeStay(in: ctx, startDay: 0, category: .destination, hex: "A")
        let a1 = makeStay(in: ctx, startDay: 1, category: .destination, hex: "A")
        makeOpenTrip(in: ctx, stays: [a1, a0], startDay: 0)
        let home = makeStay(in: ctx, startDay: 1.25, durationHours: 1, category: .home, hex: "H")
        // UUID twins with equal starts, then a phantom zero-dwell home.
        let twin = makeStay(in: ctx, startDay: 5, durationHours: 1, category: .home, hex: "H")
        makeStay(in: ctx, startDay: 5, durationHours: 1, category: .home, hex: "H").id = twin.id
        makeOpenTrip(in: ctx, stays: [makeStay(in: ctx, startDay: 4, category: .destination, hex: "B")],
                     startDay: 4)
        let phantom = makeStay(in: ctx, startDay: 12, durationHours: 0, category: .home, hex: "H")
        phantom.pingCount = 1
        makeOpenTrip(in: ctx, stays: [makeStay(in: ctx, startDay: 11, category: .destination, hex: "C")],
                     startDay: 11)
        // Ends after every home: stays open. A trip with no stays is skipped.
        makeOpenTrip(in: ctx, stays: [makeStay(in: ctx, startDay: 30, category: .destination, hex: "D")],
                     startDay: 30)
        makeOpenTrip(in: ctx, stays: [], startDay: 40)
        try ctx.save()
        #expect(home.startTime == a1.endTime)

        // The pre-change decision, read-only: start-sorted homes, first qualifying one after the end.
        let sortedHomes = FetchDescriptor<Stay>(
            predicate: #Predicate { $0.categoryRaw == "home" },
            sortBy: [SortDescriptor(\.startTime, order: .forward)])
        let qualifying = try ctx.fetch(sortedHomes).filter {
            TripClassifier.isQualifyingHomeBoundary(
                category: $0.category, source: $0.source, startTime: $0.startTime,
                endTime: $0.endTime, pingCount: $0.pingCount, hasVisit: false)
        }
        let expected = Set(try ctx.fetch(FetchDescriptor<Trip>(predicate: #Predicate { $0.isComplete == false }))
            .filter { trip in
                guard let last = trip.orderedStays.last else { return false }
                return qualifying.first { $0.startTime >= last.endTime } != nil
            }
            .map(\.id))
        #expect(expected.count == 2)

        let classifier = TripClassifier(modelContainer: container)
        let closed = await classifier.closeStaleOpenTrips()
        #expect(closed == expected.count)
        let completed = Set(await classifier.assembledTripsForTesting().filter(\.isComplete).map(\.id))
        #expect(completed == expected)
    }

    // MARK: - Upcoming-card suppression while the trip is underway

    @Test("a started journey is suppressed once a real ongoing trip overlaps it")
    func startedJourneySuppressedByOngoingTrip() {
        let suppressed = PlannedTripChainer.journeyIsSupersededByOngoingTrip(
            journeyStart: date(day: 0),
            journeyEnd: date(day: 7),
            now: date(day: 2),
            ongoingTripStartDates: [date(day: 0.5)]
        )
        #expect(suppressed == true)
    }

    @Test("a future journey always renders, even while another trip is ongoing")
    func futureJourneyNeverSuppressed() {
        let suppressed = PlannedTripChainer.journeyIsSupersededByOngoingTrip(
            journeyStart: date(day: 10),
            journeyEnd: date(day: 17),
            now: date(day: 2),
            ongoingTripStartDates: [date(day: 0.5)]
        )
        #expect(suppressed == false)
    }

    @Test("a started journey with NO ongoing trip still renders; the card may be the only trace")
    func startedJourneyWithoutOngoingTripRenders() {
        let suppressed = PlannedTripChainer.journeyIsSupersededByOngoingTrip(
            journeyStart: date(day: 0),
            journeyEnd: date(day: 7),
            now: date(day: 2),
            ongoingTripStartDates: []
        )
        #expect(suppressed == false)
    }

    @Test("an ongoing trip that starts after the journey window does not suppress it")
    func nonOverlappingOngoingTripDoesNotSuppress() {
        let suppressed = PlannedTripChainer.journeyIsSupersededByOngoingTrip(
            journeyStart: date(day: 0),
            journeyEnd: date(day: 7),
            now: date(day: 20),
            ongoingTripStartDates: [date(day: 8)]
        )
        #expect(suppressed == false)
    }

    @Test("widget and Siri skip a started journey an ongoing trip covers and name the next one")
    func nextJourneySelectionSkipsSupersededJourney() {
        let now = date(day: 10)
        let legs = [
            PlannedTripChainer.Leg(
                id: UUID(), title: "Trip to Rome",
                startDate: date(day: 9), endDate: date(day: 13), confidence: .medium
            ),
            PlannedTripChainer.Leg(
                id: UUID(), title: "Trip to Paris",
                startDate: date(day: 30), endDate: date(day: 33), confidence: .medium
            ),
        ]
        func next(ongoingTripStartDates: [Date]) -> Date? {
            PlannedTripChainer.nextJourney(
                from: legs,
                homeNames: [],
                now: now,
                ongoingTripStartDates: ongoingTripStartDates
            )?.startDate
        }
        #expect(next(ongoingTripStartDates: [date(day: 9)]) == date(day: 30))
        #expect(next(ongoingTripStartDates: []) == date(day: 9))
    }

    @Test("the qualifying-boundary rule itself", arguments: [
        // (category, source, dwellMinutes, qualifies)
        ("home", "liveSLC", 0.0, false),
        ("home", "liveSLC", 14.0, false),
        ("home", "liveSLC", 15.0, true),
        ("home", "liveSLC", 600.0, true),
        ("home", "photoImport", 0.0, true),
        ("home", "timelineImport", 0.0, true),
        ("home", "gpxImport", 0.0, true),
        ("destination", "liveSLC", 600.0, false),
    ])
    func qualifyingRuleTable(entry: (String, String, Double, Bool)) {
        let start = date(day: 0)
        let result = TripClassifier.isQualifyingHomeBoundary(
            category: StayCategory(rawValue: entry.0) ?? .unclassified,
            source: DataSource(rawValue: entry.1) ?? .liveSLC,
            startTime: start,
            endTime: start.addingTimeInterval(entry.2 * 60),
            // An accreted stay. The single-ping case is pinned separately.
            pingCount: 2,
            hasVisit: false
        )
        #expect(result == entry.3)
    }

    /// A home boundary from one ping count and Visit evidence, with the dwell
    /// in minutes from `date(day: 0)`.
    struct EvidenceRow: Sendable, CustomTestStringConvertible {
        let name: String
        let category: StayCategory
        let source: DataSource
        let dwellMinutes: Double
        let pingCount: Int
        let hasVisit: Bool
        let qualifies: Bool
        var testDescription: String { name }
    }

    /// A homecoming confirmation can create a phantom
    /// boundary the dwell rule exists to reject. When the confirmation fix
    /// lands away from home, `StayClusterer` first extends the phantom home
    /// stay's `endTime` to the midpoint of the gap. A stay that should
    /// have kept zero dwell reports gap/2, clears 15 minutes, and splits the
    /// ongoing trip unless the rule rejects its single-ping evidence.
    /// The 60 minute dwell is the midpoint extension of a 2-hour gap.
    nonisolated static let evidenceRows: [EvidenceRow] = [
        EvidenceRow(name: "a single-ping live home stay never qualifies, whatever its endTime claims",
                    category: .home, source: .liveSLC, dwellMinutes: 60,
                    pingCount: 1, hasVisit: false, qualifies: false),
        // A real homecoming accretes a second ping and still qualifies.
        EvidenceRow(name: "an accreted live home stay with the same synthetic dwell qualifies",
                    category: .home, source: .liveSLC, dwellMinutes: 60,
                    pingCount: 2, hasVisit: false, qualifies: true),
        // Unknown count (legacy rows) must behave exactly as before: refusing
        // these would stop trips closing at all.
        EvidenceRow(name: "a legacy live home stay with unknown ping count qualifies",
                    category: .home, source: .liveSLC, dwellMinutes: 60,
                    pingCount: 0, hasVisit: false, qualifies: true),
        // A lone photo at home is historical evidence, not a live glitch.
        EvidenceRow(name: "a single-ping imported home stay qualifies",
                    category: .home, source: .photoImport, dwellMinutes: 0,
                    pingCount: 1, hasVisit: false, qualifies: true),
        EvidenceRow(name: "a visit-backed single-ping live home stay qualifies at 15 minutes",
                    category: .home, source: .liveSLC, dwellMinutes: 15,
                    pingCount: 1, hasVisit: true, qualifies: true),
        EvidenceRow(name: "a visit-backed single-ping live home stay does not qualify at 14 minutes",
                    category: .home, source: .liveSLC, dwellMinutes: 14,
                    pingCount: 1, hasVisit: true, qualifies: false),
        EvidenceRow(name: "a visit-backed legacy live home stay qualifies at 15 minutes",
                    category: .home, source: .liveSLC, dwellMinutes: 15,
                    pingCount: 0, hasVisit: true, qualifies: true),
        EvidenceRow(name: "a visit-backed destination stay never qualifies",
                    category: .destination, source: .liveSLC, dwellMinutes: 15,
                    pingCount: 1, hasVisit: true, qualifies: false),
        EvidenceRow(name: "a visit-backed single-ping imported home stay qualifies",
                    category: .home, source: .photoImport, dwellMinutes: 0,
                    pingCount: 1, hasVisit: true, qualifies: true),
    ]

    @Test("the qualifying-boundary rule by ping count and Visit evidence", arguments: evidenceRows)
    func qualifyingRuleByEvidence(row: EvidenceRow) {
        let start = date(day: 0)
        #expect(TripClassifier.isQualifyingHomeBoundary(
            category: row.category, source: row.source,
            startTime: start, endTime: start.addingTimeInterval(row.dwellMinutes * 60),
            pingCount: row.pingCount, hasVisit: row.hasVisit
        ) == row.qualifies)
    }
}
