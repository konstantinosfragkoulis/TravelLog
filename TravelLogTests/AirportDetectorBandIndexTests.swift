//
//  AirportDetectorBandIndexTests.swift
//  TravelLogTests
//
//  Parity pins for the latitude-band airport index. The oracle deliberately
//  scans the shipped master dataset in file order and repeats the production
//  distance formula and tie-break without using the index.
//

import CoreLocation
import Foundation
import Testing
@testable import TravelLog

@MainActor
struct AirportDetectorBandIndexTests {

    private func loadAirports() throws -> [AirportRecord] {
        let url = try #require(
            Bundle.main.url(forResource: "airports", withExtension: "json"),
            "airports.json must be present in the test host bundle")
        let records = try JSONDecoder().decode(
            [AirportRecord].self, from: Data(contentsOf: url))
        try #require(records.count > 5000)
        return records
    }

    private func record(_ code: String, in airports: [AirportRecord]) throws -> AirportRecord {
        try #require(airports.first { $0.code == code }, "missing airport fixture \(code)")
    }

    private func distanceSquared(
        from coordinate: CLLocationCoordinate2D,
        to airport: AirportRecord
    ) -> Double {
        let metersPerDegreeLat = 111_320.0
        let avgLatRad = (coordinate.latitude + airport.lat) * 0.5 * .pi / 180
        let metersPerDegreeLon = metersPerDegreeLat * cos(avgLatRad)
        let dx = GeoMath.wrappedLongitudeDelta(coordinate.longitude, airport.lon)
            * metersPerDegreeLon
        let dy = (coordinate.latitude - airport.lat) * metersPerDegreeLat
        return dx * dx + dy * dy
    }

    private func linearIsNear(
        _ coordinate: CLLocationCoordinate2D,
        radiusMeters: Double,
        airports: [AirportRecord]
    ) -> Bool {
        let radiusSq = radiusMeters * radiusMeters
        for airport in airports {
            guard abs(airport.lat - coordinate.latitude) * 111_320 <= radiusMeters else {
                continue
            }
            if distanceSquared(from: coordinate, to: airport) <= radiusSq {
                return true
            }
        }
        return false
    }

    private func linearNearest(
        _ coordinate: CLLocationCoordinate2D,
        radiusMeters: Double,
        airports: [AirportRecord]
    ) -> AirportRecord? {
        let radiusSq = radiusMeters * radiusMeters
        var best: (record: AirportRecord, distanceSq: Double)?
        for airport in airports {
            guard abs(airport.lat - coordinate.latitude) * 111_320 <= radiusMeters else {
                continue
            }
            let distanceSq = distanceSquared(from: coordinate, to: airport)
            guard distanceSq <= radiusSq else { continue }
            if let current = best {
                if distanceSq < current.distanceSq
                    || (distanceSq == current.distanceSq && airport.code < current.record.code) {
                    best = (airport, distanceSq)
                }
            } else {
                best = (airport, distanceSq)
            }
        }
        return best?.record
    }

    @Test("latitude-band queries match a linear scan across airport grids, the equator, and antimeridian")
    func indexedQueriesMatchLinearReference() throws {
        let airports = try loadAirports()
        // The index is the only retained table: it holds every record.
        #expect(AirportDetector.shared.airportCount == airports.count)
        let gridAnchors = try ["ATH", "LHR", "JFK"].map {
            try record($0, in: airports)
        }
        var probes: [CLLocationCoordinate2D] = []
        for airport in gridAnchors {
            for latitudeOffset in [-0.04, 0, 0.04] {
                for longitudeOffset in [-0.04, 0, 0.04] {
                    probes.append(CLLocationCoordinate2D(
                        latitude: airport.lat + latitudeOffset,
                        longitude: airport.lon + longitudeOffset))
                }
            }
        }

        let mfj = try record("MFJ", in: airports)
        let tvu = try record("TVU", in: airports)
        let ebb = try record("EBB", in: airports)
        probes.append(contentsOf: [
            CLLocationCoordinate2D(latitude: mfj.lat, longitude: 179.99),
            CLLocationCoordinate2D(latitude: mfj.lat, longitude: -179.99),
            CLLocationCoordinate2D(latitude: tvu.lat, longitude: 179.99),
            CLLocationCoordinate2D(latitude: tvu.lat, longitude: -179.99),
            CLLocationCoordinate2D(latitude: 0, longitude: ebb.lon),
            CLLocationCoordinate2D(latitude: 0, longitude: 0)
        ])

        for radiusMeters in [3000.0, 15_000.0] {
            for probe in probes {
                #expect(AirportDetector.shared.isNearAirport(
                    probe, radiusMeters: radiusMeters) == linearIsNear(
                        probe, radiusMeters: radiusMeters, airports: airports))

                let indexed = AirportDetector.shared.nearestAirport(
                    probe, radiusMeters: radiusMeters)
                let linear = linearNearest(
                    probe, radiusMeters: radiusMeters, airports: airports)
                #expect(indexed?.code == linear?.code)
                #expect(indexed?.lat == linear?.lat)
                #expect(indexed?.lon == linear?.lon)
            }
        }
    }
}
