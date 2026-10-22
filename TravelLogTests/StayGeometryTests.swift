//
//  StayGeometryTests.swift
//  TravelLogTests
//

import Foundation
import Testing
@testable import TravelLog

struct StayGeometryTests {

    private let base = Date(timeIntervalSinceReferenceDate: 900_000_000)

    private func ping(
        seconds: TimeInterval,
        latitude: Double,
        longitude: Double,
        source: DataSource
    ) -> StayGeometryPing {
        StayGeometryPing(
            timestamp: base.addingTimeInterval(seconds),
            latitude: latitude,
            longitude: longitude,
            sourceRaw: source.rawValue
        )
    }

    private func visit(
        id: UUID = UUID(),
        arrival: TimeInterval,
        departure: TimeInterval? = nil,
        received: TimeInterval? = nil,
        latitude: Double = 38,
        longitude: Double = 23,
        accuracy: Double = 20
    ) -> StayGeometryVisit {
        StayGeometryVisit(
            id: id,
            arrivalDate: base.addingTimeInterval(arrival),
            departureDate: departure.map { base.addingTimeInterval($0) },
            latitude: latitude,
            longitude: longitude,
            horizontalAccuracy: accuracy,
            receivedAt: base.addingTimeInterval(received ?? arrival)
        )
    }

    @Test("reconstruction derives bounds and duration regardless of stored order")
    func derivesBoundsAndDuration() throws {
        let result = try #require(StayGeometry.recompute(from: [
            ping(seconds: 7_200, latitude: 38.2, longitude: 23.2, source: .liveSLC),
            ping(seconds: 0, latitude: 38.0, longitude: 23.0, source: .liveSLC),
            ping(seconds: 3_600, latitude: 38.1, longitude: 23.1, source: .liveSLC),
        ], visits: [], earliestAllowedStart: nil, latestAllowedEnd: nil))

        #expect(result.startTime == base)
        #expect(result.endTime == base.addingTimeInterval(7_200))
        #expect(result.durationMinutes == 120)
        #expect(abs(result.centroidLatitude - 38.1) < 1e-12)
        #expect(abs(result.centroidLongitude - 23.1) < 1e-12)
        #expect(result.sourceRaw == DataSource.liveSLC.rawValue)
    }

    @Test("longitude centroid follows the short arc across the antimeridian")
    func antimeridianCentroid() throws {
        let result = try #require(StayGeometry.recompute(from: [
            ping(seconds: 0, latitude: 0, longitude: 179.9, source: .liveSLC),
            ping(seconds: 60, latitude: 0, longitude: -179.9, source: .liveSLC),
        ], visits: [], earliestAllowedStart: nil, latestAllowedEnd: nil))

        #expect(abs(abs(result.centroidLongitude) - 180) < 1e-9)
        #expect(abs(result.centroidLatitude) < 1e-12)
    }

    @Test("mixed surviving ping sources derive merged provenance")
    func derivesMixedProvenance() throws {
        let result = try #require(StayGeometry.recompute(from: [
            ping(seconds: 0, latitude: 38, longitude: 23, source: .liveSLC),
            ping(seconds: 60, latitude: 38, longitude: 23, source: .gpxImport),
        ], visits: [], earliestAllowedStart: nil, latestAllowedEnd: nil))

        #expect(result.sourceRaw == DataSource.merged.rawValue)
    }

    @Test("foreground stream provenance normalizes to live SLC")
    func normalizesForegroundStreamProvenance() throws {
        let result = try #require(StayGeometry.recompute(from: [
            ping(seconds: 0, latitude: 38, longitude: 23, source: .foregroundStream),
            ping(seconds: 60, latitude: 38, longitude: 23, source: .foregroundStream),
        ], visits: [], earliestAllowedStart: nil, latestAllowedEnd: nil))

        #expect(result.sourceRaw == DataSource.liveSLC.rawValue)
    }

    @Test("live SLC and foreground stream provenance normalize to live SLC")
    func normalizesMixedLiveProvenance() throws {
        let result = try #require(StayGeometry.recompute(from: [
            ping(seconds: 0, latitude: 38, longitude: 23, source: .liveSLC),
            ping(seconds: 60, latitude: 38, longitude: 23, source: .foregroundStream),
        ], visits: [], earliestAllowedStart: nil, latestAllowedEnd: nil))

        #expect(result.sourceRaw == DataSource.liveSLC.rawValue)
    }

    @Test("foreground stream and photo import provenance derive merged")
    func mergesForegroundStreamAndPhotoImportProvenance() throws {
        let result = try #require(StayGeometry.recompute(from: [
            ping(seconds: 0, latitude: 38, longitude: 23, source: .foregroundStream),
            ping(seconds: 60, latitude: 38, longitude: 23, source: .photoImport),
        ], visits: [], earliestAllowedStart: nil, latestAllowedEnd: nil))

        #expect(result.sourceRaw == DataSource.merged.rawValue)
    }

    @Test("empty and invalid coordinate inputs are rejected")
    func rejectsInvalidInput() {
        #expect(StayGeometry.recompute(
            from: [], visits: [], earliestAllowedStart: nil, latestAllowedEnd: nil) == nil)
        #expect(StayGeometry.recompute(from: [
            ping(seconds: 0, latitude: 91, longitude: 23, source: .liveSLC),
        ], visits: [], earliestAllowedStart: nil, latestAllowedEnd: nil) == nil)
        #expect(StayGeometry.recompute(from: [
            ping(seconds: 0, latitude: 38, longitude: .infinity, source: .liveSLC),
        ], visits: [], earliestAllowedStart: nil, latestAllowedEnd: nil) == nil)
    }

    @Test("open Visit effective end floors at arrival and supplies centroid/source")
    func openVisitEffectiveEndAndVisitOnlyGeometry() throws {
        let result = try #require(StayGeometry.recompute(
            from: [],
            visits: [visit(arrival: 100, received: 50, latitude: 40, longitude: 25)],
            earliestAllowedStart: nil,
            latestAllowedEnd: nil
        ))

        #expect(result.startTime == base.addingTimeInterval(100))
        #expect(result.endTime == base.addingTimeInterval(100))
        #expect(result.durationMinutes == 0)
        #expect(result.centroidLatitude == 40)
        #expect(result.centroidLongitude == 25)
        #expect(result.sourceRaw == DataSource.liveSLC.rawValue)
    }

    @Test("Visits expand ping bounds without changing the ping centroid")
    func visitsExpandBoundsButNotPingCentroid() throws {
        let result = try #require(StayGeometry.recompute(from: [
            ping(seconds: 100, latitude: 10, longitude: 20, source: .liveSLC),
            ping(seconds: 200, latitude: 20, longitude: 30, source: .liveSLC),
        ], visits: [
            visit(arrival: 0, departure: 300, latitude: 60, longitude: 70),
        ], earliestAllowedStart: nil, latestAllowedEnd: nil))

        #expect(result.startTime == base)
        #expect(result.endTime == base.addingTimeInterval(300))
        #expect(result.centroidLatitude == 15)
        #expect(result.centroidLongitude == 25)
    }

    @Test("canonical Visit is closed first, then lower accuracy")
    func canonicalVisitChoice() throws {
        let result = try #require(StayGeometry.recompute(from: [], visits: [
            visit(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                  arrival: 0, received: 500, latitude: 38.000, accuracy: 1),
            visit(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                  arrival: 0, departure: 300, latitude: 38.001, accuracy: 50),
            visit(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                  arrival: 0, departure: 200, latitude: 38.002, accuracy: 5),
        ], earliestAllowedStart: nil, latestAllowedEnd: nil))

        #expect(result.endTime == base.addingTimeInterval(200))
        #expect(result.centroidLatitude == 38.002)
    }

    @Test("incompatible exact-arrival Visits form separate groups")
    func incompatibleSameArrivalVisitsRemainSeparate() throws {
        let result = try #require(StayGeometry.recompute(from: [], visits: [
            visit(arrival: 0, departure: 60, latitude: 0, longitude: 0, accuracy: 20),
            visit(arrival: 0, departure: 120, latitude: 0, longitude: 1, accuracy: 5),
        ], earliestAllowedStart: nil, latestAllowedEnd: nil))

        #expect(result.startTime == base)
        #expect(result.endTime == base.addingTimeInterval(120))
        #expect(result.centroidLongitude == 1)
    }

    @Test("invalid Visits are ignored rather than rejecting valid evidence")
    func invalidVisitIsIgnored() throws {
        let result = try #require(StayGeometry.recompute(from: [], visits: [
            visit(arrival: 10, departure: 20, latitude: 42, longitude: 24),
            visit(arrival: 0, departure: 30, latitude: .infinity, longitude: 23),
        ], earliestAllowedStart: nil, latestAllowedEnd: nil))

        #expect(result.startTime == base.addingTimeInterval(10))
        #expect(result.endTime == base.addingTimeInterval(20))
        #expect(result.centroidLatitude == 42)
    }

    @Test("neighbour window clips only Visit-derived bounds")
    func clipsVisitBoundsToNeighbours() throws {
        let result = try #require(StayGeometry.recompute(
            from: [],
            visits: [visit(arrival: 0, departure: 100)],
            earliestAllowedStart: base.addingTimeInterval(20),
            latestAllowedEnd: base.addingTimeInterval(80)
        ))

        #expect(result.startTime == base.addingTimeInterval(20))
        #expect(result.endTime == base.addingTimeInterval(80))
    }

    @Test("ping timestamps outside the neighbour window remain hard bounds")
    func pingBoundsAreNeverClamped() throws {
        let result = try #require(StayGeometry.recompute(from: [
            ping(seconds: -30, latitude: 38, longitude: 23, source: .liveSLC),
            ping(seconds: 130, latitude: 38, longitude: 23, source: .liveSLC),
        ], visits: [visit(arrival: 0, departure: 100)],
        earliestAllowedStart: base.addingTimeInterval(20),
        latestAllowedEnd: base.addingTimeInterval(80)))

        #expect(result.startTime == base.addingTimeInterval(-30))
        #expect(result.endTime == base.addingTimeInterval(130))
    }

    @Test("Visit source matrix distinguishes live-derived and imported evidence")
    func visitSourceMatrix() throws {
        let evidence = [visit(arrival: 0, departure: 60)]
        let visitOnly = try #require(StayGeometry.recompute(
            from: [], visits: evidence, earliestAllowedStart: nil, latestAllowedEnd: nil))
        let live = try #require(StayGeometry.recompute(from: [
            ping(seconds: 30, latitude: 38, longitude: 23, source: .foregroundStream),
        ], visits: evidence, earliestAllowedStart: nil, latestAllowedEnd: nil))
        let imported = try #require(StayGeometry.recompute(from: [
            ping(seconds: 30, latitude: 38, longitude: 23, source: .photoImport),
        ], visits: evidence, earliestAllowedStart: nil, latestAllowedEnd: nil))
        let noVisit = try #require(StayGeometry.recompute(from: [
            ping(seconds: 30, latitude: 38, longitude: 23, source: .gpxImport),
        ], visits: [], earliestAllowedStart: nil, latestAllowedEnd: nil))

        #expect(visitOnly.sourceRaw == DataSource.liveSLC.rawValue)
        #expect(live.sourceRaw == DataSource.liveSLC.rawValue)
        #expect(imported.sourceRaw == DataSource.merged.rawValue)
        #expect(noVisit.sourceRaw == DataSource.gpxImport.rawValue)
    }

    @Test("Visits do not perturb an antimeridian ping centroid")
    func antimeridianPingCentroidWithVisits() throws {
        let result = try #require(StayGeometry.recompute(from: [
            ping(seconds: 0, latitude: 0, longitude: 179.9, source: .liveSLC),
            ping(seconds: 60, latitude: 0, longitude: -179.9, source: .liveSLC),
        ], visits: [visit(arrival: -60, departure: 120, longitude: 0)],
        earliestAllowedStart: nil, latestAllowedEnd: nil))

        #expect(abs(abs(result.centroidLongitude) - 180) < 1e-9)
        #expect(abs(result.centroidLatitude) < 1e-12)
    }
}
