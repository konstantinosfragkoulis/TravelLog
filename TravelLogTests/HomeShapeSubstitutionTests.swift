//
//  HomeShapeSubstitutionTests.swift
//  TravelLogTests
//
//  Pins THE substitution: `matchesHome` deciding
//  home membership from the measured shape instead of `Home.radiusKm`.
//
//  These drive `matchesHome` with a shape ATTACHED, deliberately. Running the
//  suite without one proves nothing: the
//  tests exercise the synchronous core seams directly, those never call
//  `primeHomeShapes()`, so the cache is empty and every ring degrades to the
//  legacy circle. That fallback is intentional — a missed prime must not make
//  "nothing is home" — but it means the substitution needs its own pins.
//

import Foundation
import CoreLocation
import Testing
@testable import TravelLog

struct HomeShapeSubstitutionTests {

    private static let home = (lat: 38.0, lon: 23.8)

    private static func ring(radiusKm: Double, shape: HomeShape?) -> TripClassifier.HomeRing {
        TripClassifier.HomeRing(
            latitude: home.lat, longitude: home.lon, radiusKm: radiusKm,
            startedAt: Date(timeIntervalSince1970: 0), endedAt: nil,
            membership: shape.map { HomeMembership(seed: $0) })
    }

    private static func isHome(_ lat: Double, _ lon: Double,
                              _ r: TripClassifier.HomeRing) -> Bool {
        TripClassifier.matchesHome(stayStart: Date(timeIntervalSince1970: 1_700_000_000),
                                   latitude: lat, longitude: lon, homes: [r])
    }

    @Test("with no shape attached, the legacy circle still decides")
    func fallbackIsUnchanged() {
        let r = Self.ring(radiusKm: 30, shape: nil)
        // Livadeiá is about 94.3 km out, outside a 30 km ring.
        #expect(!Self.isHome(38.4366, 22.8758, r))
        // The airport is about 14.5 km out, inside a 30 km ring. This is the bug.
        #expect(Self.isHome(37.9364, 23.9445, r))
    }

    @Test("with a shape attached, the shape decides — and fixes the airport")
    func shapeReplacesTheCircle() async {
        let shape = await HomeShapeResolver.resolve(latitude: Self.home.lat,
                                                    longitude: Self.home.lon)
        // Same 30 km radius on the ring; the shape must override it.
        let r = Self.ring(radiusKm: 30, shape: shape)
        // Athens International is outside the built-up city -> no longer home.
        #expect(!Self.isHome(37.9364, 23.9445, r), "ATH should stop being home")
        // Real suburbs stay home.
        for (name, lat, lon) in [("Níkaia", 37.96667, 23.65),
                                 ("Néa Pentéli", 38.0606, 23.8593),
                                 ("Távros", 37.97064, 23.69043)] {
            #expect(Self.isHome(lat, lon, r), "\(name) must remain home")
        }
        // Real destinations stay away.
        for (name, lat, lon) in [("Livadeiá", 38.4366, 22.8758),
                                 ("Syros", 37.4465, 24.9419)] {
            #expect(!Self.isHome(lat, lon, r), "\(name) must not be home")
        }
    }

    @Test("the shape narrows home where the radius was too generous")
    func shapeIsNotJustASmallerCircle() async {
        let shape = await HomeShapeResolver.resolve(latitude: Self.home.lat,
                                                    longitude: Self.home.lon)
        let shaped = Self.ring(radiusKm: 30, shape: shape)
        let circle = Self.ring(radiusKm: 30, shape: nil)
        // Níkaia (13.7 km southwest) stays home while ATH (14.5 km southeast)
        // does not. Both fit the 30 km circle, but only Níkaia fits the shape.
        #expect(Self.isHome(37.96667, 23.65, shaped))
        #expect(!Self.isHome(37.9364, 23.9445, shaped))
        #expect(Self.isHome(37.96667, 23.65, circle))
        #expect(Self.isHome(37.9364, 23.9445, circle))
    }

    @Test("a home with no urban centre falls back to the 1 km disc, not to nothing")
    func nonUrbanHomeStillHasAHome() async {
        // Open Aegean — no urban centre anywhere near.
        //
        // NOTE this pins the ENGINE's resolver contract (never fails, disc
        // as last resort); end-to-end `withShapes` substitution is owned by
        // HomeShapeGateTests.
        let shape = await HomeShapeResolver.resolve(latitude: 37.5, longitude: 24.6)
        #expect(shape.seed == .fallbackDisc)
        let r = TripClassifier.HomeRing(
            latitude: 37.5, longitude: 24.6, radiusKm: 25,
            startedAt: Date(timeIntervalSince1970: 0), endedAt: nil,
            membership: HomeMembership(seed: shape))
        #expect(TripClassifier.matchesHome(
            stayStart: Date(timeIntervalSince1970: 1_700_000_000),
            latitude: 37.5, longitude: 24.6, homes: [r]))
    }

    // The old `rolloutIsOn` pin (a bare assert on the flag constant) is
    // replaced by HomeShapeGateTests.withShapesAttachesUrbanCentre, which
    // fails when the flag is off — a behavioral pin instead of a
    // configuration pin, so an emergency rollback edits test expectations
    // that MEAN something rather than a tautology.
}
