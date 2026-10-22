//
//  HomeShapeGateTests.swift
//  TravelLogTests
//
//  Coverage for the assembly confidence gate: window-scoped memberships
//  (`gateMemberships`), the fallback-disc
//  guard in `withShapes`, and the suppressed-residue fingerprint memo that
//  keeps `assemblyInvariantViolated` quiet in the gate's steady state.
//
//  `primeShapeForTesting` supplies shapes to the actor so these tests
//  exercise the gate instead of its empty-shapes decline.
//
//  Pattern (TripAssemblyTests / OngoingTripReuseTests): seed prior state by
//  hand via a plain context + save, then read results ONLY through the
//  actor's seams — assembleTrips doesn't save, so a fresh ModelContext can't
//  see its in-context changes.
//

import Foundation
import CoreLocation
import SwiftData
import Testing
@testable import TravelLog

@MainActor @Suite(IsolatedLineageDefaults())
struct HomeShapeGateTests {

    private static let day: TimeInterval = 24 * 60 * 60
    private static let home = (lat: 38.0, lon: 23.8)

    private func date(day offset: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: (offset + 175) * Self.day)
    }

    /// A synthetic urban centre: a square ~±0.05° around the test home.
    /// `areaKm2 = 100` ⇒ `D* = √(100/π) ≈ 5.64 km`. Rings are FLAT
    /// [x0, y0, x1, y1, …] per the `WKBPolygon` contract.
    private static func squareShape() -> HomeShape {
        HomeShape.urbanCentre(
            id: 1, name: "TestCity", areaKm2: 100,
            rings: [[[23.75, 37.95, 23.85, 37.95, 23.85, 38.05, 23.75, 38.05]]],
            centreLatitude: home.lat, centreLongitude: home.lon)
    }

    @discardableResult
    private func makeStay(
        in ctx: ModelContext,
        startDay: Double,
        durationHours: Double = 2,
        latitude: Double,
        longitude: Double,
        category: StayCategory = .destination,
        hex: String,
        userOverridden: Bool = false
    ) -> Stay {
        let start = date(day: startDay)
        let stay = Stay(
            startTime: start,
            endTime: start.addingTimeInterval(durationHours * 3600),
            centroidLatitude: latitude, centroidLongitude: longitude,
            h3IndexRes6: hex,
            pingCount: 2,
            distanceFromHomeKm: 10, pingIDs: []
        )
        stay.category = category
        stay.userOverridden = userOverridden
        ctx.insert(stay)
        return stay
    }

    private func makeHome(in ctx: ModelContext, startDay: Double) {
        let home = Home(label: "Home", latitude: Self.home.lat,
                        longitude: Self.home.lon, radiusKm: 25,
                        startedAt: date(day: startDay))
        ctx.insert(home)
    }

    // MARK: - gateMemberships: the window mirror (pure)

    private func ring(
        startDay: Double, endDay: Double?, shape: HomeShape?
    ) -> TripClassifier.HomeRing {
        TripClassifier.HomeRing(
            latitude: Self.home.lat, longitude: Self.home.lon, radiusKm: 25,
            startedAt: date(day: startDay),
            endedAt: endDay.map { date(day: $0) },
            membership: shape.map { HomeMembership(seed: $0) })
    }

    @Test("an ended home's shape scores only groups from its own era")
    func endedHomeShapeIsWindowScoped() {
        let oldShape = HomeShape.fallbackDisc(latitude: 10, longitude: 10)
        let newShape = HomeShape.fallbackDisc(latitude: 20, longitude: 20)
        let rings = [ring(startDay: -100, endDay: 5, shape: oldShape),
                     ring(startDay: 8, endDay: nil, shape: newShape)]
        // A post-move group (day 10) must NOT see the ended home's shape —
        // the pre-fix `Array(resolvedHomeShapes.values)` did, and a visit
        // back to the former city was suppressed forever.
        #expect(TripClassifier.gateMemberships(
            stayStarts: [date(day: 10)], rings: rings).map(\.seed) == [newShape])
        // A group from the OLD era sees the old shape (docs §5: the shape
        // valid when it happened).
        #expect(TripClassifier.gateMemberships(
            stayStarts: [date(day: 0)], rings: rings).map(\.seed) == [oldShape])
    }

    @Test("a group predating every home scores against all shaped rings (pre-history mirror)")
    func preHistoryFallback() {
        let shape = Self.squareShape()
        let rings = [ring(startDay: 100, endDay: nil, shape: shape)]
        // Home.startedAt defaults to onboarding time, so imported history
        // predates the row. A bare window-overlap filter would return [] and
        // the gate would decline — materializing the phantoms it exists to
        // suppress. matchesHome's pre-history fallback is mirrored instead.
        #expect(TripClassifier.gateMemberships(
            stayStarts: [date(day: 10), date(day: 20)], rings: rings).map(\.seed) == [shape])
    }

    @Test("a genuinely home-less middle era yields no shapes (gate declines, legacy behavior)")
    func homelessMiddleEra() {
        let rings = [ring(startDay: -100, endDay: 0,
                          shape: HomeShape.fallbackDisc(latitude: 10, longitude: 10)),
                     ring(startDay: 100, endDay: nil,
                          shape: HomeShape.fallbackDisc(latitude: 20, longitude: 20))]
        #expect(TripClassifier.gateMemberships(
            stayStarts: [date(day: 10)], rings: rings).isEmpty)
    }

    @Test("a group straddling a home's start still sees its shape")
    func straddlingGroup() {
        let shape = Self.squareShape()
        let rings = [ring(startDay: 5, endDay: nil, shape: shape)]
        #expect(TripClassifier.gateMemberships(
            stayStarts: [date(day: 0), date(day: 10)], rings: rings).map(\.seed) == [shape])
    }

    // MARK: - withShapes: primed membership

    @Test("withShapes attaches a primed urban-centre shape")
    func withShapesAttachesUrbanCentre() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let classifier = TripClassifier(modelContainer: container)
        let shape = Self.squareShape()
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon, shape: shape)
        let rings = await classifier.withShapes(
            [ring(startDay: 0, endDay: nil, shape: nil)])
        #expect(rings.first?.shape == shape)
    }

    @Test("withShapes attaches the fallback disc to a non-urban-centre home")
    func withShapesAttachesFallbackDisc() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: HomeShape.fallbackDisc(latitude: Self.home.lat,
                                          longitude: Self.home.lon))
        let rings = await classifier.withShapes(
            [ring(startDay: 0, endDay: nil, shape: nil)])
        #expect(rings.first?.shape?.seed == .fallbackDisc)
    }

    @Test("withShapes leaves a temporary home's membership undated: only the gate dates it, so the form's preview still reads the whole area")
    func withShapesAttachesNoEra() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon, shape: Self.squareShape())
        let temporary = TripClassifier.HomeRing(HomeAnchor(
            id: UUID(), kind: .temporary, label: "Semester",
            latitude: Self.home.lat, longitude: Self.home.lon, radiusKm: 25,
            locality: nil, isoCountryCode: nil,
            startedAt: date(day: 10), endedAt: date(day: 20)))
        let rings = await classifier.withShapes(
            [temporary, ring(startDay: 0, endDay: nil, shape: nil)])
        #expect(rings.count == 2)
        #expect(rings.allSatisfy { $0.membership != nil && $0.membership?.era == nil })
        #expect(rings.first?.isTemporary == true)
    }

    // MARK: - The assembly gate

    @Test("a sub-θ group is suppressed, stays tripless, and the invariant stays quiet")
    func subThresholdGroupIsSuppressed() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(in: ctx, startDay: -10)
        // Two stays ~7.9 km beyond the square's edge, 4 h total:
        // score = log₂(1 + 7.89/5.64) × (1 + log₂(1 + 4/24)) ≈ 1.54 < θ = 2.
        makeStay(in: ctx, startDay: 0, latitude: 38.0, longitude: 23.94, hex: "A")
        makeStay(in: ctx, startDay: 0.1, latitude: 38.0, longitude: 23.94, hex: "A")
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        let created = await classifier.assembleTrips()
        #expect(created == 0, "the errand group must not become a trip")
        // The suppressed residue is the gate's steady state. The invariant
        // must not re-arm the back half every pass: its destination-only
        // check predates the gate and would otherwise fire forever.
        #expect(await classifier.assemblyInvariantViolated() == false)
    }

    @Test("the invariant re-arms for a NEW unassigned destination stay")
    func invariantReArmsOnNewStay() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(in: ctx, startDay: -10)
        makeStay(in: ctx, startDay: 0, latitude: 38.0, longitude: 23.94, hex: "A")
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        _ = await classifier.assembleTrips()
        #expect(await classifier.assemblyInvariantViolated() == false)

        // A stay the gate never saw is real unassigned residue.
        makeStay(in: ctx, startDay: 5, latitude: 38.0, longitude: 23.94, hex: "B")
        try ctx.save()
        #expect(await classifier.assemblyInvariantViolated() == true)
    }

    @Test("the invariant re-arms when a suppressed stay's endTime drifts (accretion)")
    func invariantReArmsOnEndTimeDrift() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(in: ctx, startDay: -10)
        let stay = makeStay(in: ctx, startDay: 0, latitude: 38.0, longitude: 23.94, hex: "A")
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        _ = await classifier.assembleTrips()
        #expect(await classifier.assemblyInvariantViolated() == false)

        // Clustering extends endTime without minting an unclassified stay.
        // Duration feeds the score. One stay 7.89 km out
        // needs 1.262 × (1 + log₂(1 + T/24)) ≥ 2 ⇒ T ≈ 12.0 h to clear θ.
        // Short of that instant the verdict cannot change, so the memo must
        // keep excusing the stay. The foreground stream flushes every 30 s,
        // and each re-arm is a full assembly.
        stay.endTime = stay.startTime.addingTimeInterval(8 * 3600)
        try ctx.save()
        #expect(await classifier.assemblyInvariantViolated() == false,
                "8 h of dwell cannot lift this group over θ; no re-arm")

        // At the crossing the fingerprint must go stale and hand the group
        // back to the gate.
        stay.endTime = stay.startTime.addingTimeInterval(13 * 3600)
        try ctx.save()
        #expect(await classifier.assemblyInvariantViolated() == true)
    }

    @Test("the invariant re-arms when a suppressed stay's endTime shrinks or its startTime moves")
    func invariantReArmsOnNonAccretionDrift() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(in: ctx, startDay: -10)
        let stay = makeStay(in: ctx, startDay: 0, latitude: 38.0, longitude: 23.94, hex: "A")
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        _ = await classifier.assembleTrips()
        #expect(await classifier.assemblyInvariantViolated() == false)

        // An import can extend startTime BACKWARD (duration grows with no
        // endTime change) — not an accretion the memo may excuse.
        stay.startTime = stay.startTime.addingTimeInterval(-3600)
        try ctx.save()
        #expect(await classifier.assemblyInvariantViolated() == true)

        _ = await classifier.assembleTrips()
        #expect(await classifier.assemblyInvariantViolated() == false)

        // A shrink (ping deletion / dedup) is a real change too.
        stay.endTime = stay.endTime.addingTimeInterval(-600)
        try ctx.save()
        #expect(await classifier.assemblyInvariantViolated() == true)
    }

    @Test("the invariant re-arms when a suppressed stay's centroid drifts far enough to move its home distance")
    func invariantReArmsOnCentroidDrift() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(in: ctx, startDay: -10)
        let stay = makeStay(in: ctx, startDay: 0, latitude: 38.0, longitude: 23.94, hex: "A")
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        _ = await classifier.assembleTrips()
        #expect(await classifier.assemblyInvariantViolated() == false)

        // The clusterer restamps distanceFromHomeKm with every accreted
        // ping. Jitter under the tolerance is excused …
        stay.distanceFromHomeKm += 0.1
        stay.endTime = stay.endTime.addingTimeInterval(60)
        try ctx.save()
        #expect(await classifier.assemblyInvariantViolated() == false)

        // … a real move is not.
        stay.distanceFromHomeKm += 0.5
        try ctx.save()
        #expect(await classifier.assemblyInvariantViolated() == true)
    }

    @Test("the invariant re-arms when the centroid moves 0.4 km tangentially")
    func invariantReArmsOnTangentialCentroidDrift() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(in: ctx, startDay: -10)
        let stay = makeStay(in: ctx, startDay: 0, latitude: 38.0, longitude: 23.94, hex: "A")
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        _ = await classifier.assembleTrips()
        #expect(await classifier.assemblyInvariantViolated() == false)

        stay.centroidLatitude += 0.4 / 111.0
        try ctx.save()
        #expect(await classifier.assemblyInvariantViolated() == true)
    }

    @Test("the invariant still excuses 0.1 km of centroid drift")
    func invariantExcusesSmallCentroidDrift() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(in: ctx, startDay: -10)
        let stay = makeStay(in: ctx, startDay: 0, latitude: 38.0, longitude: 23.94, hex: "A")
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        _ = await classifier.assembleTrips()
        #expect(await classifier.assemblyInvariantViolated() == false)

        stay.centroidLatitude += 0.1 / 111.0
        try ctx.save()
        #expect(await classifier.assemblyInvariantViolated() == false)
    }

    @Test("the invariant re-arms when a suppressed stay's airport state changes")
    func invariantReArmsOnAirportStateChange() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(in: ctx, startDay: -10)
        let stay = makeStay(in: ctx, startDay: 0, latitude: 38.0, longitude: 23.94, hex: "A")
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        _ = await classifier.assembleTrips()
        #expect(await classifier.assemblyInvariantViolated() == false)

        stay.isAirport.toggle()
        try ctx.save()
        #expect(await classifier.assemblyInvariantViolated() == true)
    }

    @Test("a userOverridden stay exempts its whole group from the gate")
    func userOverriddenGroupIsExempt() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(in: ctx, startDay: -10)
        makeStay(in: ctx, startDay: 0, latitude: 38.0, longitude: 23.94, hex: "A",
                 userOverridden: true)
        makeStay(in: ctx, startDay: 0.1, latitude: 38.0, longitude: 23.94, hex: "A")
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        let created = await classifier.assembleTrips()
        #expect(created == 1, "the user has answered; the score may not overrule them")
    }

    @Test("with no shape primed the gate declines and the trip is minted, never deleted")
    func missedPrimeMintsRatherThanDeletes() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(in: ctx, startDay: -10)
        makeStay(in: ctx, startDay: 0, latitude: 38.0, longitude: 23.94, hex: "A")
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        let created = await classifier.assembleTrips()
        #expect(created == 1)
    }

    @Test("a fallback-disc prime reaches the gate end-to-end")
    func fallbackDiscPrimeReachesGate() async throws {
        // A 2 h
        // outing ~12 km beyond a 1 km disc scores ≈ 4.0 ≥ θ — a genuine
        // trip for a disc-seed home — while a 2 h errand just past the disc
        // edge scores well under θ and is suppressed (recoverable via
        // Near-Home Activity, healable once the orbit learns the spot).
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(in: ctx, startDay: -10)
        makeStay(in: ctx, startDay: 0, latitude: 38.0, longitude: 23.94, hex: "A")
        // Home boundary between the two candidate groups.
        makeStay(in: ctx, startDay: 1, latitude: Self.home.lat,
                 longitude: Self.home.lon, category: .home, hex: "H")
        // The errand: ~1.6 km from the home point, 0.6 km past the disc.
        makeStay(in: ctx, startDay: 2, latitude: 38.0, longitude: 23.818, hex: "B")
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: HomeShape.fallbackDisc(latitude: Self.home.lat,
                                          longitude: Self.home.lon))
        let created = await classifier.assembleTrips()
        #expect(created == 1, "the far outing is a trip; the disc-edge errand is suppressed")
    }

    @Test("current membership covers the suburb and user includes, but excludes the airport")
    func coversPointMatchesLiveMembership() async throws {
        // Probe full membership against the bundled geocoder, including user overrides.
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let home = Home(label: "Home", latitude: 38.0,
                        longitude: 23.8, radiusKm: 30,
                        startedAt: date(day: -100))
        ctx.insert(home)
        try ctx.save()
        let classifier = TripClassifier(modelContainer: container)

        // ATH is inside the declared circle but outside the Athens urban centre.
        #expect(await classifier.currentMembershipCovers(
            latitude: 37.9461, longitude: 23.9469) == false)
        // Agios Dimitrios stays home.
        #expect(await classifier.currentMembershipCovers(
            latitude: 37.9343, longitude: 23.7341) == true)
        // A user include extends full membership beyond the seed.
        ctx.insert(HomeAreaOverride(
            kind: .include, centerLatitude: 38.35, centerLongitude: 24.05,
            radiusKm: 1, homeID: home.id))
        try ctx.save()
        #expect(await classifier.currentMembershipCovers(
            latitude: 38.35, longitude: 24.05) == true)
    }

    @Test("current membership for a non-urban-centre home uses the fallback disc and learned orbit")
    func discCohortIsLive() async throws {
        // Open Aegean membership uses the 1 km seed plus any learned orbit discs.
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let home = Home(label: "Island", latitude: 37.5, longitude: 24.6,
                        radiusKm: 25, startedAt: date(day: -100))
        ctx.insert(home)
        try ctx.save()
        let classifier = TripClassifier(modelContainer: container)

        // 15 km out was "home" under the circle; it is not any more.
        #expect(await classifier.currentMembershipCovers(
            latitude: 37.5, longitude: 24.77) == false)
        // 0.5 km out is inside the disc.
        #expect(await classifier.currentMembershipCovers(
            latitude: 37.5045, longitude: 24.6) == true)
    }

    @Test("tripless destination residue is invisible to Places and weather-card gating")
    func triplessResidueIsInvisibleToStayAggregates() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // One real trip-backed destination stay, one gate-residue stay.
        let onTrip = makeStay(in: ctx, startDay: 0, latitude: 38.4326, longitude: 22.8738, hex: "T")
        onTrip.locality = "Livadeiá"
        let trip = Trip(startDate: onTrip.startTime)
        ctx.insert(trip)
        onTrip.trip = trip
        let residue = makeStay(in: ctx, startDay: 5, latitude: 38.0, longitude: 23.94, hex: "R")
        residue.locality = "Pentéli"
        try ctx.save()

        // Places: only the trip-backed stay mints a row (pre-fix, Pentéli
        // appeared as a phantom tripCount-0 row in the user's own city).
        let places = CollectionsAggregator.placeEntriesForTesting(byStart: [onTrip, residue])
        #expect(places.count == 1)
        #expect(places.first?.name == "Livadeiá")

        // Weather-card gating: an unmeasured tripless destination stay must
        // not change the verdict — the enricher never fetches it, so the
        // mirror must never wait for it.
        let withResidue = YearWrappedGenerator.weatherExtremesSafe(allStays: [onTrip, residue])
        let withoutResidue = YearWrappedGenerator.weatherExtremesSafe(allStays: [onTrip])
        #expect(withResidue == withoutResidue)
    }

    @Test("a clearly-far group still clears the gate (contrast pin)")
    func farGroupClearsGate() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(in: ctx, startDay: -10)
        // ~65 km beyond the shape: score ≈ 4.5 ≥ θ.
        makeStay(in: ctx, startDay: 0, durationHours: 4,
                 latitude: 38.0, longitude: 24.6, hex: "F")
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon,
            shape: Self.squareShape())
        let created = await classifier.assembleTrips()
        #expect(created == 1)
    }
}
