//
//  CollectionsProximityOracleTests.swift
//  TravelLogTests
//
//  Oracle-equality pins for the sphere-bucket cull in CollectionsAggregator's
//  two proximity passes. Candidate discovery changes; exact haversine checks,
//  donor ordering, and component identities must match the all-pairs reference.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

/// Deterministic RNG so a failing geometry is reproducible from its seed.
private struct SeededLCG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

@MainActor
struct CollectionsProximityOracleTests {

    // MARK: - Fixture generation

    /// Clustered + scattered stays around a lat range wide enough that the
    /// spatial cull actually culls, with distances straddling both radii.
    private func randomStays(
        seed: UInt64, count: Int,
        islandDonorRatio: Double = 0.3
    ) -> [Stay] {
        var rng = SeededLCG(state: seed)
        let centers = (0..<6).map { _ in
            (lat: Double.random(in: 35.0...41.0, using: &rng),
             lon: Double.random(in: 20.0...28.0, using: &rng))
        }
        let isos: [String?] = ["GR", "GR", "IT", nil]
        let islands = ["Cephalonia", "Syros", "Aegina", "Ios"]
        var stays: [Stay] = []
        for i in 0..<count {
            let center = centers[Int.random(in: 0..<centers.count, using: &rng)]
            // Jitter spans ~0-30 km so pairs land on BOTH sides of the 5 km
            // adoption radius and the 25 km cluster threshold.
            // One WHOLE UTC day apart per stay: each stay contributes exactly
            // one distinct day to its place entry, so an entry's `days` set
            // doubles as an exact MEMBERSHIP fingerprint (size+order
            // alone can't catch two equal-sized clusters exchanging members).
            let stay = Stay(
                startTime: Date(timeIntervalSince1970: 1_723_993_600 + Double(i) * 86_400),
                endTime: Date(timeIntervalSince1970: 1_723_993_600 + Double(i) * 86_400 + 1800),
                centroidLatitude: center.lat + Double.random(in: -0.15...0.15, using: &rng),
                centroidLongitude: center.lon + Double.random(in: -0.15...0.15, using: &rng),
                h3IndexRes6: "hex\(i)", pingCount: 1,
                distanceFromHomeKm: 100, pingIDs: [])
            stay.category = .destination
            stay.isoCountryCode = isos[Int.random(in: 0..<isos.count, using: &rng)]
            if Double.random(in: 0...1, using: &rng) < islandDonorRatio {
                stay.islandName = islands[Int.random(in: 0..<islands.count, using: &rng)]
            }
            stay.administrativeArea = "Region"
            stays.append(stay)
        }
        return stays
    }

    // MARK: - All-pairs references (verbatim pre-band logic)

    private func referenceAdoptedIslands(destinations: [Stay]) -> [PersistentIdentifier: String] {
        let donors = destinations.filter { ($0.islandName?.isEmpty == false) }
        guard !donors.isEmpty else { return [:] }
        var adopted: [PersistentIdentifier: String] = [:]
        for stay in destinations {
            guard (stay.metroName ?? "").isEmpty, (stay.islandName ?? "").isEmpty else { continue }
            var best: (name: String, distanceKm: Double, donorID: String)?
            for donor in donors {
                if let a = stay.isoCountryCode, let b = donor.isoCountryCode, a != b { continue }
                let d = CollectionsAggregator.haversineKm(
                    lat1: stay.centroidLatitude, lon1: stay.centroidLongitude,
                    lat2: donor.centroidLatitude, lon2: donor.centroidLongitude)
                guard d <= CollectionsAggregator.islandAdoptionRadiusKm,
                      let name = donor.islandName else { continue }
                if let current = best {
                    // Mirrors production's (distance, donorID, name)
                    // tie-break — the name key was added 2026-08-09 so the
                    // choice stays total even for CloudKit-duplicated donors
                    // sharing a UUID at equal distance.
                    if d < current.distanceKm
                        || (d == current.distanceKm && donor.id.uuidString < current.donorID)
                        || (d == current.distanceKm && donor.id.uuidString == current.donorID
                            && name < current.name) {
                        best = (name, d, donor.id.uuidString)
                    }
                } else {
                    best = (name, d, donor.id.uuidString)
                }
            }
            if let best { adopted[stay.persistentModelID] = best.name }
        }
        return adopted
    }

    /// All-pairs union-find components over the filtered unnamed subset,
    /// as (min-root-ordered) member-count lists — the exact structure the
    /// production pass turns into `area#` entries.
    private func referenceComponents(unnamed: [Stay]) -> [[UUID]] {
        let rows = unnamed.filter {
            if let admin = $0.administrativeArea, !admin.isEmpty { return true }
            return false
        }
        guard !rows.isEmpty else { return [] }
        var parent = Array(0..<rows.count)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for i in 0..<rows.count {
            for j in (i + 1)..<rows.count {
                let d = CollectionsAggregator.haversineKm(
                    lat1: rows[i].centroidLatitude, lon1: rows[i].centroidLongitude,
                    lat2: rows[j].centroidLatitude, lon2: rows[j].centroidLongitude)
                if d <= CollectionsAggregator.areaClusterThresholdKm {
                    let ri = find(i), rj = find(j)
                    if ri != rj { parent[max(ri, rj)] = min(ri, rj) }
                }
            }
        }
        var clusters: [Int: [UUID]] = [:]
        for i in 0..<rows.count {
            clusters[find(i), default: []].append(rows[i].id)
        }
        return clusters.keys.sorted().compactMap { clusters[$0] }
    }

    // MARK: - The pins

    @Test("island adoption: sphere-bucket production equals the all-pairs reference",
          arguments: [UInt64(1), 7, 42, 1234, 987_654])
    func islandAdoptionMatchesOracle(seed: UInt64) throws {
        _ = try TestSupport.makeInMemoryContainer()  // isolates @Model init
        let stays = randomStays(seed: seed, count: 70)
        let production = CollectionsAggregator.adoptedIslandNames(destinations: stays)
        let reference = referenceAdoptedIslands(destinations: stays)
        #expect(production == reference, "seed \(seed): adoption maps diverged")
        #expect(!reference.isEmpty, "seed \(seed) generated no adoptions — fixture too sparse to prove anything")
    }

    @Test("area clustering: sphere-bucket production yields identical components in identical order",
          arguments: [UInt64(3), 11, 99, 4242, 31_337])
    func areaClustersMatchOracle(seed: UInt64) throws {
        _ = try TestSupport.makeInMemoryContainer()
        // No island/metro names: every stay lands in the unnamed subset.
        let stays = randomStays(seed: seed, count: 80, islandDonorRatio: 0)

        var entries: [String: CollectionsAggregator.PlaceEntry] = [:]
        var tripIDs: [String: Set<UUID>] = [:]
        var days: [String: Set<Date>] = [:]
        var order: [String] = []
        CollectionsAggregator.appendAreaClusters(
            unnamed: stays, entries: &entries, tripIDs: &tripIDs,
            days: &days, order: &order)

        let expected = referenceComponents(unnamed: stays)
        #expect(order.count == expected.count,
                "seed \(seed): component count diverged")
        #expect(expected.count > 1,
                "seed \(seed) collapsed to one cluster — fixture proves nothing")
        // Entries appear in min-root order; each key's stayCount must be its
        // component's size, in the same order.
        let productionSizes = order.compactMap { entries[$0]?.stayCount }
        #expect(productionSizes == expected.map(\.count),
                "seed \(seed): component sizes or order diverged")
        // EXACT membership, not just sizes: every stay carries a unique UTC
        // day (see the fixture), so a component's day-set identifies its
        // members. Computed with the production `utcDays` so the fingerprint
        // can't drift from the code under test.
        let stayByID = Dictionary(uniqueKeysWithValues: stays.map { ($0.id, $0) })
        let expectedDaySets: [Set<Date>] = expected.map { component in
            Set(component.flatMap { id -> [Date] in
                guard let stay = stayByID[id] else { return [] }
                return CollectionsAggregator.utcDays(start: stay.startTime, end: stay.endTime)
            })
        }
        let productionDaySets: [Set<Date>] = order.map { days[$0] ?? [] }
        #expect(productionDaySets == expectedDaySets,
                "seed \(seed): component MEMBERSHIP diverged despite matching sizes")
    }

    @Test("band edge: a due-north pair just inside the radius unions; just outside does not")
    func nearThresholdNorthSouthPairs() throws {
        _ = try TestSupport.makeInMemoryContainer()
        // Purely-latitudinal separation is the WORST case for the band cull —
        // the pair sits exactly at the band boundary's own axis. The first
        // fixture placed the pair by the band's conservative 110.574 km/°
        // constant and accidentally proved the OPPOSITE case: the spherical
        // haversine metric is ~111.195 km/°, so that pair was 25.04 km apart
        // and correctly rejected by BOTH implementations. Place fixtures by
        // the production metric itself so the test can't drift from it.
        let make: (Double) -> Stay = { lat in
            let s = Stay(startTime: .now, endTime: .now,
                         centroidLatitude: lat, centroidLongitude: 23.7,
                         h3IndexRes6: "h", pingCount: 1,
                         distanceFromHomeKm: 100, pingIDs: [])
            s.category = .destination
            s.administrativeArea = "Region"
            return s
        }

        func cluster(_ stays: [Stay]) -> [Int] {
            var entries: [String: CollectionsAggregator.PlaceEntry] = [:]
            var tripIDs: [String: Set<UUID>] = [:]
            var days: [String: Set<Date>] = [:]
            var order: [String] = []
            CollectionsAggregator.appendAreaClusters(
                unnamed: stays, entries: &entries, tripIDs: &tripIDs,
                days: &days, order: &order)
            return order.compactMap { entries[$0]?.stayCount }
        }

        // Just INSIDE: haversine-verified < 25 km, near the band edge.
        let inside = [make(38.0), make(38.0 + 24.8 / 111.195)]
        let dIn = CollectionsAggregator.haversineKm(
            lat1: inside[0].centroidLatitude, lon1: 23.7,
            lat2: inside[1].centroidLatitude, lon2: 23.7)
        #expect(dIn <= CollectionsAggregator.areaClusterThresholdKm,
                "fixture drifted: 'inside' pair measures \(dIn) km")
        #expect(cluster(inside) == [2], "the just-inside N-S pair must form ONE cluster")

        // Just OUTSIDE: > 25 km — must stay two clusters (and would even
        // without the band, since the exact check rejects it).
        let outside = [make(38.0), make(38.0 + 25.2 / 111.195)]
        let dOut = CollectionsAggregator.haversineKm(
            lat1: outside[0].centroidLatitude, lon1: 23.7,
            lat2: outside[1].centroidLatitude, lon2: 23.7)
        #expect(dOut > CollectionsAggregator.areaClusterThresholdKm,
                "fixture drifted: 'outside' pair measures \(dOut) km")
        #expect(cluster(outside) == [1, 1], "the just-outside N-S pair must stay two clusters")
    }

    private func stay(latitude: Double, longitude: Double, ordinal: Int) -> Stay {
        let start = Date(timeIntervalSince1970: 1_750_000_000 + Double(ordinal) * 86_400)
        let row = Stay(startTime: start, endTime: start.addingTimeInterval(1800),
                       centroidLatitude: latitude, centroidLongitude: longitude,
                       h3IndexRes6: "", pingCount: 1,
                       distanceFromHomeKm: 100, pingIDs: [])
        row.category = .destination
        row.administrativeArea = "Region"
        return row
    }

    @Test("Physical recipient UUID twins retain their own nearby island")
    func recipientTwinsAdoptIndependently() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let a = stay(latitude: 0, longitude: 0, ordinal: 0)
        let b = stay(latitude: 30, longitude: 30, ordinal: 1)
        b.id = a.id
        let donorA = stay(latitude: 0, longitude: 0.01, ordinal: 2)
        donorA.islandName = "Alpha"
        let donorB = stay(latitude: 30, longitude: 30.01, ordinal: 3)
        donorB.islandName = "Beta"
        let rows = [a, b, donorA, donorB]
        for row in rows { context.insert(row) }
        try context.save()
        for order in [rows, Array(rows.reversed())] {
            let adopted = CollectionsAggregator.adoptedIslandNames(destinations: order)
            #expect(adopted[a.persistentModelID] == "Alpha")
            #expect(adopted[b.persistentModelID] == "Beta")
            #expect(adopted.count == 2)
        }
    }

    @Test("sphere buckets preserve adoption and exact components across the dateline and poles")
    func datelineAndPolesMatchOracle() throws {
        _ = try TestSupport.makeInMemoryContainer()
        let coordinates: [(Double, Double)] = [
            (0, 179.99), (0, -179.99),
            (89.99, 0), (89.99, 180),
            (-89.99, 0), (-89.99, 180),
            (30, 45),
        ]
        let stays = coordinates.enumerated().map {
            stay(latitude: $0.element.0, longitude: $0.element.1, ordinal: $0.offset)
        }
        for i in [0, 2, 4] { stays[i].islandName = "Island \(i)" }
        let expectedAdoptions = referenceAdoptedIslands(destinations: stays)
        #expect(expectedAdoptions.count == 3)
        #expect(CollectionsAggregator.adoptedIslandNames(destinations: stays) == expectedAdoptions)
        #expect(CollectionsAggregator.adoptedIslandNames(destinations: Array(stays.reversed())) == expectedAdoptions)

        var entries: [String: CollectionsAggregator.PlaceEntry] = [:]
        var tripIDs: [String: Set<UUID>] = [:]
        var days: [String: Set<Date>] = [:]
        var order: [String] = []
        CollectionsAggregator.appendAreaClusters(
            unnamed: stays, entries: &entries, tripIDs: &tripIDs, days: &days, order: &order)
        let expected = referenceComponents(unnamed: stays)
        #expect(expected.map(\.count) == [2, 2, 2, 1])
        let byID = Dictionary(uniqueKeysWithValues: stays.map { ($0.id, $0) })
        let expectedDays = expected.map { component in
            Set(component.flatMap { id in
                CollectionsAggregator.utcDays(start: byID[id]!.startTime, end: byID[id]!.endTime)
            })
        }
        #expect(order.map { days[$0] ?? [] } == expectedDays)
    }

    @Test("sphere buckets preserve same-coordinate donor name ties and country filtering")
    func equalDonorsMatchOracle() throws {
        _ = try TestSupport.makeInMemoryContainer()
        let recipient = stay(latitude: 0, longitude: -179.99, ordinal: 0)
        recipient.isoCountryCode = "GR"
        let first = stay(latitude: 0, longitude: 179.99, ordinal: 1)
        first.isoCountryCode = "GR"
        first.islandName = "Zulu"
        let second = stay(latitude: 0, longitude: 179.99, ordinal: 2)
        second.id = first.id
        second.isoCountryCode = "GR"
        second.islandName = "Alpha"
        let foreign = stay(latitude: 0, longitude: -179.99, ordinal: 3)
        foreign.isoCountryCode = "IT"
        foreign.islandName = "Wrong country"
        let rows = [recipient, first, second, foreign]
        let expected = referenceAdoptedIslands(destinations: rows)
        #expect(expected[recipient.persistentModelID] == "Alpha")
        #expect(CollectionsAggregator.adoptedIslandNames(destinations: rows) == expected)
        #expect(CollectionsAggregator.adoptedIslandNames(destinations: Array(rows.reversed())) == expected)

        // A missing country retains the existing wildcard semantics: the
        // nearer donor remains eligible instead of getting dropped by indexing.
        foreign.isoCountryCode = nil
        #expect(CollectionsAggregator.adoptedIslandNames(destinations: rows)
                == referenceAdoptedIslands(destinations: rows))
        #expect(CollectionsAggregator.adoptedIslandNames(destinations: rows)[recipient.persistentModelID] == "Wrong country")
    }

    @Test("same-latitude global stays inspect nearby buckets instead of every longitude")
    func sameLatitudeCandidateWorkload() throws {
        _ = try TestSupport.makeInMemoryContainer()
        let stays = (0..<720).map {
            stay(latitude: 0, longitude: -180 + Double($0) * 0.5, ordinal: $0)
        }
        let index = CollectionsAggregator.ProximityBuckets(
            rows: stays.map { CollectionsAggregator.StayRow($0) },
            radiusKm: CollectionsAggregator.areaClusterThresholdKm, checkCancellation: {})
        let candidateCount = stays.reduce(0) { count, row in
            count + index.candidates(latitude: row.centroidLatitude,
                                     longitude: row.centroidLongitude).count
        }
        // The previous latitude band visited all 720 squared candidates.
        // Use counted candidate work rather than a machine-dependent timer.
        #expect(candidateCount < stays.count * 8)
        #expect(candidateCount >= stays.count)
    }

    @Test("proximity cancellation interrupts bucket construction")
    func bucketConstructionCancellation() {
        let rows = (0..<128).map { CollectionsAggregator.StayRow(stay(latitude: 38, longitude: 24, ordinal: $0)) }
        var calls = 0
        #expect(throws: CancellationError.self) {
            try CollectionsAggregator.ProximityBuckets(rows: rows, radiusKm: 25) {
                calls += 1
                if calls == 64 { throw CancellationError() }
            }
        }
        #expect(calls == 64)
    }

    @Test("proximity cancellation interrupts dense candidate materialization")
    func bucketCandidateCancellation() {
        let rows = (0..<128).map { stay(latitude: 38, longitude: 24, ordinal: $0) }
        let index = CollectionsAggregator.ProximityBuckets(
            rows: rows.map { CollectionsAggregator.StayRow($0) }, radiusKm: 25, checkCancellation: {})
        var calls = 0
        #expect(throws: CancellationError.self) {
            try index.candidates(latitude: 38, longitude: 24) {
                calls += 1
                // More calls than the 27 cells can supply: inside members.
                if calls == 64 { throw CancellationError() }
            }
        }
        #expect(calls == 64)
        #expect(index.candidates(latitude: 38, longitude: 24).count == rows.count)
    }

}
