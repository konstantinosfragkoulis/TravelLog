//
//  PingRecorderImportAirportRestampTests.swift
//  TravelLogTests
//
//  Pins airport status after an imported ping is attached to a stay.
//  `attachImportedPing` updates the
//  running centroid with the same formula as StayClusterer's extend branch,
//  so it must ALSO re-stamp `isAirport` from the drifted centroid. Pre-fix,
//  a Stay seeded on the fringe of the ATH ring kept its seed-derived flag
//  forever when absorbed import pings pulled its centroid across the 3 km
//  boundary.
//
//  Same real-dataset discipline as `StayClustererAirportRestampTests`:
//  every fixture's in-ring/out-of-ring status is `#require`d against the
//  bundled airports.json before acting, so a dataset change fails loudly
//  in arrange, not mysteriously in assert.
//

import Testing
import Foundation
import SwiftData
import CoreLocation
@testable import TravelLog

@MainActor
@Suite("PingRecorder import-attach airport re-stamp")
struct PingRecorderImportAirportRestampTests {

    /// ATH reference point (OurAirports), the centre of its 3 km ring.
    private static let athRef = (lat: 37.9364, lon: 23.9445)
    /// Degrees of latitude per km (WGS84 mean) — fixtures move due north/
    /// south so only latitude arithmetic is needed.
    private static let degPerKm = 1.0 / 111.32
    private let base = Date(timeIntervalSince1970: 1_600_000_000)

    private func requireNear(_ lat: Double, _ lon: Double, _ expected: Bool) throws {
        let near = AirportDetector.shared.isNearAirport(
            CLLocationCoordinate2D(latitude: lat, longitude: lon))
        try #require(near == expected,
                     "fixture (\(lat), \(lon)) expected isNearAirport == \(expected) — dataset changed?")
    }

    /// Hand-built prior state (the actor-seam seeding pattern): a
    /// single-ping Stay at `lat` carrying the given (possibly stale)
    /// seed-derived `isAirport` stamp.
    private func seedStay(in container: ModelContainer, lat: Double, isAirport: Bool) throws -> UUID {
        let ctx = ModelContext(container)
        let hex = H3Service.cellIndex(latitude: lat, longitude: Self.athRef.lon) ?? ""
        let stay = Stay(
            startTime: base, endTime: base.addingTimeInterval(3600),
            centroidLatitude: lat, centroidLongitude: Self.athRef.lon,
            h3IndexRes6: hex, pingCount: 1, distanceFromHomeKm: 50,
            pingIDs: [UUID()]
        )
        stay.isAirport = isAirport
        ctx.insert(stay)
        try ctx.save()
        return stay.id
    }

    private func fetchStay(_ id: UUID, in container: ModelContainer) throws -> Stay {
        let ctx = ModelContext(container)
        let predicate = #Predicate<Stay> { $0.id == id }
        return try #require(try ctx.fetch(FetchDescriptor<Stay>(predicate: predicate)).first)
    }

    private func candidate(_ lat: Double, secondsAfterBase: TimeInterval) -> ImportedPingCandidate {
        ImportedPingCandidate(
            timestamp: base.addingTimeInterval(secondsAfterBase),
            latitude: lat, longitude: Self.athRef.lon,
            horizontalAccuracy: 10, altitude: nil, verticalAccuracy: nil
        )
    }

    @Test("import absorption that drags the centroid INTO the ring flips isAirport true")
    func importDriftIntoRingFlagsAirport() async throws {
        // Stay seeded 3.4 km north of the ATH reference — outside the ring…
        let seedLat = Self.athRef.lat + 3.4 * Self.degPerKm
        try requireNear(seedLat, Self.athRef.lon, false)
        // …import ping 1.0 km north — inside the ring, and 2.4 km from the
        // centroid so it lands inside the 3 km attach envelope. Post-attach
        // centroid (n=2 running average = midpoint) sits 2.2 km north —
        // inside the ring.
        let pingLat = Self.athRef.lat + 1.0 * Self.degPerKm
        try requireNear(pingLat, Self.athRef.lon, true)
        try requireNear((seedLat + pingLat) / 2, Self.athRef.lon, true)

        let container = try TestSupport.makeInMemoryContainer()
        let stayID = try seedStay(in: container, lat: seedLat, isAirport: false)
        let rec = PingRecorder(modelContainer: container)

        let accepted = try await rec.recordImportedPings([candidate(pingLat, secondsAfterBase: 600)])
        try await rec.saveImportBatch()

        #expect(accepted == 1)
        let stay = try fetchStay(stayID, in: container)
        #expect(stay.pingCount == 2)        // proves the pre-attach absorbed the ping
        #expect(stay.isAirport == true)     // re-stamped from the merged centroid
    }

    @Test("import absorption that drags the centroid OUT of the ring clears a stale isAirport")
    func importDriftOutOfRingClearsAirport() async throws {
        // Stay seeded 2.6 km north — inside the ring…
        let seedLat = Self.athRef.lat + 2.6 * Self.degPerKm
        try requireNear(seedLat, Self.athRef.lon, true)
        // …import ping 5.0 km north — outside the ring, 2.4 km from the
        // centroid. Post-attach centroid sits 3.8 km north — outside.
        let pingLat = Self.athRef.lat + 5.0 * Self.degPerKm
        try requireNear(pingLat, Self.athRef.lon, false)
        try requireNear((seedLat + pingLat) / 2, Self.athRef.lon, false)

        let container = try TestSupport.makeInMemoryContainer()
        let stayID = try seedStay(in: container, lat: seedLat, isAirport: true)
        let rec = PingRecorder(modelContainer: container)

        _ = try await rec.recordImportedPings([candidate(pingLat, secondsAfterBase: 600)])
        try await rec.saveImportBatch()

        let stay = try fetchStay(stayID, in: container)
        #expect(stay.pingCount == 2)
        #expect(stay.isAirport == false)    // stale seed stamp cleared
    }
}
