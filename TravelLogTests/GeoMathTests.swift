//
//  GeoMathTests.swift
//  TravelLogTests
//
//  The shared longitude-wrap primitives behind the geometry
//  sweep (the antimeridian family and the city-dedup group centroid).
//  Two contracts matter:
//
//  1. AWAY from the date line every primitive is numerically identical to
//     the naive math it replaced — that identity is the sweep's
//     no-regression proof, so it is pinned here explicitly.
//  2. ACROSS ±180° the primitives produce the geographically-correct
//     answer the naive math got wrong (Fiji/Chukotka fixtures).
//

import Foundation
import CoreLocation
import Testing
@testable import TravelLog

struct GeoMathTests {

    // MARK: - Normalization and deltas

    @Test("normalizedLongitude wraps into [-180, 180)")
    func normalization() {
        #expect(GeoMath.normalizedLongitude(0) == 0)
        #expect(GeoMath.normalizedLongitude(179.5) == 179.5)
        #expect(GeoMath.normalizedLongitude(-179.5) == -179.5)
        #expect(GeoMath.normalizedLongitude(180) == -180)
        #expect(GeoMath.normalizedLongitude(190) == -170)
        #expect(GeoMath.normalizedLongitude(-190) == 170)
        #expect(GeoMath.normalizedLongitude(540) == -180)
        #expect(GeoMath.normalizedLongitude(-540) == -180)
    }

    @Test("wrappedLongitudeDelta equals plain subtraction away from the date line")
    func deltaMatchesNaiveMathAwayFromDateline() {
        #expect(GeoMath.wrappedLongitudeDelta(23.7, 20.0) == 23.7 - 20.0)
        #expect(GeoMath.wrappedLongitudeDelta(-74.0, -73.0) == -1.0)
        #expect(GeoMath.wrappedLongitudeDelta(100.0, -60.0) == 160.0)
    }

    @Test("wrappedLongitudeDelta takes the short arc across ±180°")
    func deltaWrapsAcrossDateline() {
        #expect(abs(GeoMath.wrappedLongitudeDelta(179.9, -179.9) - (-0.2)) < 1e-9)
        #expect(abs(GeoMath.wrappedLongitudeDelta(-179.9, 179.9) - 0.2) < 1e-9)
    }

    // MARK: - Means

    @Test("runningMeanLongitude matches the linear update away from the date line")
    func runningMeanMatchesLinearUpdate() {
        // The exact update StayClusterer/PingRecorder used: c + (x − c) / n.
        let c = 23.72, x = 23.75, n = 4.0
        let linear = c + (x - c) / n
        #expect(abs(GeoMath.runningMeanLongitude(current: c, adding: x, newCount: n) - linear) < 1e-12)
    }

    @Test("runningMeanLongitude stays on the date line for straddling clusters")
    func runningMeanAcrossDateline() {
        // Fiji-side cluster: centroid at +179.9, new ping at −179.9 (0.2°
        // east). The linear update dragged the centroid to ~0° (Greenwich);
        // the wrapped update nudges it toward the line.
        let updated = GeoMath.runningMeanLongitude(current: 179.9, adding: -179.9, newCount: 2)
        // Midpoint of +179.9 and −179.9 is ±180.0 — NOT ~0° (Greenwich).
        #expect(abs(abs(updated) - 180.0) < 1e-9)
    }

    // MARK: - Windows

    @Test("longitudeWindowHalfWidth scales by 1/cos(lat) and caps at the full circle")
    func windowScaling() {
        #expect(GeoMath.longitudeWindowHalfWidth(equatorDegrees: 0.05, atLatitude: 0) == 0.05)
        let at60 = GeoMath.longitudeWindowHalfWidth(equatorDegrees: 0.05, atLatitude: 60)
        #expect(abs(at60 - 0.1) < 1e-9)   // cos 60° = 0.5
        #expect(GeoMath.longitudeWindowHalfWidth(equatorDegrees: 0.05, atLatitude: 89.9) == 180)
    }

    @Test("longitudeSegments returns one segment inland, two across ±180°")
    func windowSegments() {
        let plain = GeoMath.longitudeSegments(center: 23.7, halfWidth: 0.05)
        #expect(plain.count == 1)
        #expect(abs(plain[0].min - 23.65) < 1e-9 && abs(plain[0].max - 23.75) < 1e-9)

        let east = GeoMath.longitudeSegments(center: 179.98, halfWidth: 0.05)
        #expect(east.count == 2)
        #expect(GeoMath.segmentsContain(east, longitude: 179.99))
        #expect(GeoMath.segmentsContain(east, longitude: -179.99))
        #expect(!GeoMath.segmentsContain(east, longitude: 0))

        let west = GeoMath.longitudeSegments(center: -179.98, halfWidth: 0.05)
        #expect(west.count == 2)
        #expect(GeoMath.segmentsContain(west, longitude: 179.99))
        #expect(GeoMath.segmentsContain(west, longitude: -179.99))

        let full = GeoMath.longitudeSegments(center: 0, halfWidth: 200)
        #expect(full.count == 1)
        #expect(full[0].min == -180 && full[0].max == 180)
    }

    // MARK: - Point in polygon

    private func square(centerLat: Double, centerLon: Double, half: Double) -> [CLLocationCoordinate2D] {
        [
            CLLocationCoordinate2D(latitude: centerLat - half, longitude: GeoMath.normalizedLongitude(centerLon - half)),
            CLLocationCoordinate2D(latitude: centerLat - half, longitude: GeoMath.normalizedLongitude(centerLon + half)),
            CLLocationCoordinate2D(latitude: centerLat + half, longitude: GeoMath.normalizedLongitude(centerLon + half)),
            CLLocationCoordinate2D(latitude: centerLat + half, longitude: GeoMath.normalizedLongitude(centerLon - half)),
        ]
    }

    @Test("pointInPolygon matches classic behavior for an ordinary polygon")
    func pipOrdinary() {
        let athens = square(centerLat: 38.0, centerLon: 23.7, half: 0.1)
        #expect(GeoMath.pointInPolygon(CLLocationCoordinate2D(latitude: 38.0, longitude: 23.7), polygon: athens))
        #expect(!GeoMath.pointInPolygon(CLLocationCoordinate2D(latitude: 38.5, longitude: 23.7), polygon: athens))
        #expect(!GeoMath.pointInPolygon(CLLocationCoordinate2D(latitude: 38.0, longitude: 24.0), polygon: athens))
    }

    @Test("pointInPolygon accepts points on BOTH sides of a date-line-straddling polygon")
    func pipAcrossDateline() {
        // A Taveuni-style square across ±180° (vertices at +179.9 and −179.9).
        let fiji = square(centerLat: -16.8, centerLon: 180.0, half: 0.1)
        #expect(GeoMath.pointInPolygon(CLLocationCoordinate2D(latitude: -16.8, longitude: 179.95), polygon: fiji))
        #expect(GeoMath.pointInPolygon(CLLocationCoordinate2D(latitude: -16.8, longitude: -179.95), polygon: fiji))
        #expect(!GeoMath.pointInPolygon(CLLocationCoordinate2D(latitude: -16.8, longitude: 179.5), polygon: fiji))
        #expect(!GeoMath.pointInPolygon(CLLocationCoordinate2D(latitude: -16.8, longitude: 0), polygon: fiji))
    }

    // MARK: - Bounding box

    @Test("boundingLongitude is a tight box for a date-line-straddling cluster")
    func boundingAcrossDateline() {
        let box = GeoMath.boundingLongitude(of: [179.8, -179.8, 179.9])
        #expect(box != nil)
        if let box {
            #expect(abs(box.span - 0.4) < 1e-9)                 // NOT ~359.7
            #expect(abs(abs(box.center) - 180.0) < 0.01)        // centered on the line
        }
    }

    @Test("boundingLongitude matches plain min/max away from the date line")
    func boundingOrdinary() {
        let box = GeoMath.boundingLongitude(of: [23.7, 25.2, 24.0])
        #expect(box != nil)
        if let box {
            #expect(abs(box.span - 1.5) < 1e-9)
            #expect(abs(box.center - 24.45) < 1e-9)
        }
    }

    // MARK: - City-dedup group centroid (fixture)

    @Test("deduplicatedCityCount does not mint a phantom Greenwich centroid for a date-line hex group")
    @MainActor
    func cityDedupDatelineGroup() {
        // Two stays in the same res-6 hex group straddling ±180°, plus a
        // genuinely distinct city 30 km away on the same side. Pre-fix, the
        // group's centroid averaged to ~0° (Greenwich), tens of thousands
        // of km from the third stay — the union-find then saw TWO distant
        // "cities" where the truth is two nearby ones.
        func stay(lat: Double, lon: Double, hex: String) -> Stay {
            let s = Stay(
                startTime: .now, endTime: .now,
                centroidLatitude: lat, centroidLongitude: lon,
                h3IndexRes6: hex, pingCount: 1,
                distanceFromHomeKm: 0, pingIDs: []
            )
            s.category = .destination
            return s
        }
        let group = [
            stay(lat: -16.8, lon: 179.9, hex: "FIJI"),
            stay(lat: -16.8, lon: -179.9, hex: "FIJI"),
            stay(lat: -16.8, lon: 179.6, hex: "NEARBY"), // ~32 km west
        ]
        // Group centroid lands on ±180; the second node is ~32 km away —
        // beyond the default 25 km threshold — so the count is exactly 2.
        // (A phantom Greenwich centroid would ALSO produce 2 here, so pin
        // the tighter contract: with a 50 km threshold the two must MERGE,
        // which is impossible if the group centroid sits near 0°.)
        #expect(Stay.deduplicatedCityCount(from: group, thresholdKm: 50) == 1)
        #expect(Stay.deduplicatedCityCount(from: group, thresholdKm: 25) == 2)
    }
}
