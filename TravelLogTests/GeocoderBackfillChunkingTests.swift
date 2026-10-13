//
//  GeocoderBackfillChunkingTests.swift
//  TravelLogTests
//
//  Tests for the chunked offline-geocoder backfill. Two contracts:
//
//  1. Behavior parity — the phased snapshot→resolve→gated-apply worker
//     still updates every layer (pings, stays, hex visits) and recomputes +
//     title-clears affected trips, exactly like the old single-gate-unit
//     pass.
//
//  2. The gate is FREE between apply chunks. The inter-chunk probe enqueues
//     a competing unit on the SAME gate and awaits its completion; the gate
//     is non-reentrant, so if any chunk (or a resurrected outer wrapper —
//     the regression this suite exists to catch) held the gate across a
//     chunk boundary, the probe would deadlock and the time limit turns
//     that into a clean failure instead of a hung suite.
//
//  Uses the real bundled GeocodeResolver at Athens coordinates (the
//  documented resolver flake is parallel-load-only; this suite is
//  `.serialized` and the standard run is serial).
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

private actor ProbeCounter {
    private(set) var completions = 0
    func bump() { completions += 1 }
}

@MainActor
@Suite("Geocoder backfill chunking", .serialized)
struct GeocoderBackfillChunkingTests {

    private static let base = Date(timeIntervalSinceReferenceDate: 722 * 86_400)
    private let athens = (lat: 37.9838, lon: 23.7275)
    private let athensHex = "8a1eda743a8ffff"

    private func seedPing(_ ctx: ModelContext, offset: TimeInterval) -> LocationPing {
        let ping = LocationPing(
            timestamp: Self.base.addingTimeInterval(offset),
            latitude: athens.lat, longitude: athens.lon,
            horizontalAccuracy: 30, h3IndexRes6: athensHex, source: .liveSLC
        )
        ctx.insert(ping)
        return ping
    }

    private func seedStay(_ ctx: ModelContext, startOffset: TimeInterval) -> Stay {
        let stay = Stay(
            startTime: Self.base.addingTimeInterval(startOffset),
            endTime: Self.base.addingTimeInterval(startOffset + 3_600),
            centroidLatitude: athens.lat, centroidLongitude: athens.lon,
            h3IndexRes6: athensHex, pingCount: 1,
            distanceFromHomeKm: 40, pingIDs: []
        )
        stay.category = .destination
        ctx.insert(stay)
        return stay
    }

    @Test("chunked worker updates every layer and recomputes affected trips")
    func chunkedBackfillAppliesAllLayers() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        // The resolver must be live for this pin to mean anything — fail
        // loudly here rather than passing over zero-resolution no-ops.
        let probeResult = await GeocodeResolver.shared.resolve(
            latitude: athens.lat, longitude: athens.lon
        )
        _ = try #require(probeResult, "bundled geocoder did not resolve Athens — resolver unavailable in this run")

        for i in 0..<3 { _ = seedPing(ctx, offset: Double(i) * 600) }
        let trip = Trip(startDate: Self.base)
        trip.aiGeneratedTitle = "Stale Mixed-Script Title"
        ctx.insert(trip)
        let stay = seedStay(ctx, startOffset: 0)
        stay.trip = trip
        let hex = HexVisit(
            h3Index: athensHex, firstVisited: Self.base,
            centerLatitude: athens.lat, centerLongitude: athens.lon
        )
        ctx.insert(hex)
        try ctx.save()
        let tripID = trip.id

        let result = await AppDelegate.backfillOfflineGeocoder(
            modelContainer: container, gate: PipelineGate(forTesting: ())
        )

        #expect(result.saved, "clean in-memory run must report saved")
        #expect(result.updatedPings == 3)
        #expect(result.updatedStays == 1)
        #expect(result.updatedHexVisits == 1)
        #expect(result.recomputedTrips == 1)

        let fresh = ModelContext(container)
        let stays = try fresh.fetch(FetchDescriptor<Stay>())
        let seededStay = try #require(stays.first)
        #expect(seededStay.isoCountryCode == "GR")
        #expect(seededStay.locality != nil)
        let pings = try fresh.fetch(FetchDescriptor<LocationPing>())
        #expect(pings.count == 3)
        #expect(pings.allSatisfy { $0.isoCountryCode == "GR" })
        let hexes = try fresh.fetch(FetchDescriptor<HexVisit>())
        #expect(hexes.first?.isoCountryCode == "GR")
        let predicate = #Predicate<Trip> { $0.id == tripID }
        let reloaded = try #require(try fresh.fetch(FetchDescriptor<Trip>(predicate: predicate)).first)
        #expect(reloaded.aiGeneratedTitle == nil,
                "geocode backfill must clear stale AI titles on touched trips")
    }

    @Test("an identical stay resolution preserves canonical and localized titles")
    func identicalStayResolutionPreservesTitles() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let resolved = try #require(await GeocodeResolver.shared.resolve(
            latitude: athens.lat, longitude: athens.lon))

        let trip = Trip(startDate: Self.base)
        trip.aiGeneratedTitle = "Athens Return"
        ctx.insert(trip)
        let stay = seedStay(ctx, startOffset: 0)
        stay.trip = trip
        stay.orderInTrip = 0
        if resolved.bestLocalityName != nil {
            stay.locality = resolved.localityForStorage
        }
        stay.administrativeArea = resolved.administrativeArea
        stay.country = resolved.country
        stay.isoCountryCode = resolved.isoCountryCode
        stay.subLocality = resolved.subLocalityName
        stay.metroName = resolved.metroName
        stay.islandName = resolved.islandName
        ctx.insert(TripTitleVariant(
            languageTag: "el",
            title: "Επιστροφή στην Αθήνα",
            sourceTitle: "Athens Return",
            trip: trip))
        let tripID = trip.id
        try ctx.save()

        let result = await AppDelegate.backfillOfflineGeocoder(
            modelContainer: container,
            gate: PipelineGate(forTesting: ()))

        #expect(result.saved)
        #expect(result.recomputedTrips == 0)
        let fresh = ModelContext(container)
        let saved = try #require(try fresh.fetch(
            FetchDescriptor<Trip>(
                predicate: #Predicate { $0.id == tripID })
        ).first)
        #expect(saved.aiGeneratedTitle == "Athens Return")
        #expect((saved.localizedTitles ?? []).count == 1)
    }

    @Test("the gate is free between apply chunks — a competing unit interleaves",
          .timeLimit(.minutes(1)))
    func gateIsFreeBetweenApplyChunks() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let probeResult = await GeocodeResolver.shared.resolve(
            latitude: athens.lat, longitude: athens.lon
        )
        _ = try #require(probeResult, "bundled geocoder did not resolve Athens — resolver unavailable in this run")

        // Two full ping chunks plus a remainder → three gated apply units.
        let pingCount = AppDelegate.geocoderBackfillPingChunk * 2 + 1
        for i in 0..<pingCount { _ = seedPing(ctx, offset: Double(i)) }
        _ = seedStay(ctx, startOffset: 0)
        try ctx.save()

        let gate = PipelineGate(forTesting: ())
        let counter = ProbeCounter()
        AppDelegate.geocoderBackfillInterChunkProbe = { @Sendable in
            // Competing "wake-ping save": a unit on the SAME gate. Completing
            // at all proves no gate unit spans this chunk boundary — under a
            // resurrected outer wrapper this deadlocks and trips the time limit.
            await gate.run(touching: [.locationPing]) {}
            await counter.bump()
        }
        defer { AppDelegate.geocoderBackfillInterChunkProbe = nil }

        let result = await AppDelegate.backfillOfflineGeocoder(
            modelContainer: container, gate: gate
        )

        #expect(result.updatedPings == pingCount, "chunking must not drop rows")
        #expect(result.updatedStays == 1)
        let completions = await counter.completions
        #expect(completions >= 3,
                "expected a competing gate unit to complete after each of ≥3 apply chunks; got \(completions)")
    }

    @Test("apply chunks are GATED: nothing lands in the store while a competing unit holds the gate",
          .timeLimit(.minutes(1)))
    func appliesWaitBehindAHeldGate() async throws {
        // The inter-chunk probe checks that the gate is free between chunks.
        // Here a competing unit holds the gate, so no apply may reach the
        // store until that unit releases it.
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let probeResult = await GeocodeResolver.shared.resolve(
            latitude: athens.lat, longitude: athens.lon
        )
        _ = try #require(probeResult, "bundled geocoder did not resolve Athens — resolver unavailable in this run")

        for i in 0..<25 { _ = seedPing(ctx, offset: Double(i)) }
        try ctx.save()

        let gate = PipelineGate(forTesting: ())
        let latch = TestLatch()
        let holderStarted = TestLatch()
        let holder = Task {
            await gate.run(touching: .all) {
                await holderStarted.release()
                await latch.wait()
            }
        }
        // Await the holder's signal from inside its gate unit so the
        // backfill starts only after the holder has acquired the gate.
        await holderStarted.wait()

        let applyAttempted = TestLatch()
        let attempts = ProbeCounter()
        let backfill = Task {
            await AppDelegate.GeocoderBackfillTestScope.$beforeApply.withValue({ @Sendable in
                await attempts.bump()
                await applyAttempted.release()
            }) {
                await AppDelegate.backfillOfflineGeocoder(modelContainer: container, gate: gate)
            }
        }
        // Resolution has completed and the first apply is attempting admission
        // while the holder is still parked; no scheduler-delay assumption.
        await applyAttempted.wait()
        #expect(await attempts.completions == 1, "the first apply must reach gate admission")
        // A non-throwing read lets the test release the gate even if the
        // read fails, so the holder and backfill can finish.
        let geocodedWhileHeld = (try? ModelContext(container).fetchCount(
            FetchDescriptor<LocationPing>(
                predicate: #Predicate { $0.isoCountryCode != nil }))) ?? -1
        #expect(geocodedWhileHeld == 0,
                "an apply wrote the store while the gate was HELD — the applies are no longer gated")

        await latch.release()
        let result = await backfill.value
        await holder.value
        #expect(result.updatedPings == 25, "applies must land once the gate frees")
    }

    // MARK: - Physical UUID twins

    private let munich = (lat: 48.1374, lon: 11.5755)

    @Test("every physical UUID twin takes its own coordinate's resolution",
          .timeLimit(.minutes(1)), arguments: [false, true])
    func twinsEachTakeTheirOwnResolution(athensInsertedFirst: Bool) async throws {
        let athensResult = try #require(await GeocodeResolver.shared.resolve(
            latitude: athens.lat, longitude: athens.lon))
        let munichResult = try #require(await GeocodeResolver.shared.resolve(
            latitude: munich.lat, longitude: munich.lon))
        try #require(athensResult.isoCountryCode == "GR")
        try #require(munichResult.isoCountryCode == "DE")

        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let pingID = UUID()
        let stayID = UUID()
        let hexID = UUID()
        var expected: [PersistentIdentifier: String] = [:]
        var seededPings: [(LocationPing, String)] = []
        var seededStays: [(Stay, String)] = []
        var seededHexes: [(HexVisit, String)] = []
        let places: [(lat: Double, lon: Double, cell: String, iso: String)] = athensInsertedFirst
            ? [(athens.lat, athens.lon, athensHex, "GR"), (munich.lat, munich.lon, "munich-cell", "DE")]
            : [(munich.lat, munich.lon, "munich-cell", "DE"), (athens.lat, athens.lon, athensHex, "GR")]
        for place in places {
            let ping = LocationPing(
                timestamp: Self.base, latitude: place.lat, longitude: place.lon,
                horizontalAccuracy: 30, h3IndexRes6: place.cell, source: .jsonImport)
            ping.id = pingID
            ctx.insert(ping)
            let trip = Trip(startDate: Self.base)
            trip.aiGeneratedTitle = "Stale Title"
            ctx.insert(trip)
            let stay = Stay(
                startTime: Self.base, endTime: Self.base.addingTimeInterval(3_600),
                centroidLatitude: place.lat, centroidLongitude: place.lon,
                h3IndexRes6: place.cell, pingCount: 1, distanceFromHomeKm: 40, pingIDs: [pingID])
            stay.id = stayID
            stay.category = .destination
            stay.locality = "Stale"
            stay.trip = trip
            stay.orderInTrip = 0
            ctx.insert(stay)
            let hex = HexVisit(
                h3Index: place.cell, firstVisited: Self.base,
                centerLatitude: place.lat, centerLongitude: place.lon)
            hex.id = hexID
            ctx.insert(hex)
            seededPings.append((ping, place.iso))
            seededStays.append((stay, place.iso))
            seededHexes.append((hex, place.iso))
        }
        try ctx.save()
        for (row, iso) in seededPings { expected[row.persistentModelID] = iso }
        for (row, iso) in seededStays { expected[row.persistentModelID] = iso }
        for (row, iso) in seededHexes { expected[row.persistentModelID] = iso }

        let result = await AppDelegate.backfillOfflineGeocoder(
            modelContainer: container, gate: PipelineGate(forTesting: ()))

        #expect(result.saved)
        #expect(result.updatedPings == 2)
        #expect(result.updatedStays == 2)
        #expect(result.updatedHexVisits == 2)
        #expect(result.recomputedTrips == 2, "each twin's own parent is invalidated")
        let fresh = ModelContext(container)
        let pings = try fresh.fetch(FetchDescriptor<LocationPing>())
        let stays = try fresh.fetch(FetchDescriptor<Stay>())
        let hexes = try fresh.fetch(FetchDescriptor<HexVisit>())
        #expect(pings.count == 2 && stays.count == 2 && hexes.count == 2)
        for ping in pings { #expect(ping.isoCountryCode == expected[ping.persistentModelID]) }
        for stay in stays {
            #expect(stay.isoCountryCode == expected[stay.persistentModelID])
            #expect(stay.locality != "Stale")
        }
        for hex in hexes { #expect(hex.isoCountryCode == expected[hex.persistentModelID]) }
        #expect(try fresh.fetch(FetchDescriptor<Trip>()).allSatisfy { $0.aiGeneratedTitle == nil })
    }

    @Test("a device that latched the twin-collapsing v10 pass reruns it and heals every twin",
          .timeLimit(.minutes(1)))
    func v10LatchedDeviceRerunsAndHealsTwins() async throws {
        _ = try #require(await GeocodeResolver.shared.resolve(
            latitude: athens.lat, longitude: athens.lon))
        let suite = "offline-geocoder-backfill-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        // The v10 pass applied both twins' results to one row and latched.
        defaults.set(true, forKey: "offlineGeocoderBackfillCompleted_v10")

        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let stayID = UUID()
        for offset in [0.0, 7_200] {
            let trip = Trip(startDate: Self.base.addingTimeInterval(offset))
            ctx.insert(trip)
            let stay = seedStay(ctx, startOffset: offset)
            stay.id = stayID
            stay.locality = "Stale"
            stay.trip = trip
            stay.orderInTrip = 0
        }
        try ctx.save()

        await AppDelegate.runOfflineGeocoderBackfillIfNeeded(
            modelContainer: container, defaults: defaults)

        let stays = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        #expect(stays.count == 2)
        #expect(stays.allSatisfy { $0.isoCountryCode == "GR" && $0.locality != "Stale" },
                "the twin the v10 pass skipped is healed too")
        #expect(defaults.bool(forKey: AppDelegate.offlineGeocoderBackfillCompletedKey))
    }

    @Test("a HexVisit re-keyed after the snapshot is still applied; a same-UUID replacement is left alone",
          .timeLimit(.minutes(1)))
    func rekeyedHexIsAppliedAndReplacementIsSkipped() async throws {
        _ = try #require(await GeocodeResolver.shared.resolve(
            latitude: athens.lat, longitude: athens.lon))
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // One full apply chunk plus two rows: the probe after the first chunk
        // runs once the snapshot is taken and before the second chunk applies.
        let total = AppDelegate.geocoderBackfillHexChunk + 2
        for i in 0..<total {
            ctx.insert(HexVisit(
                h3Index: String(format: "cell-%04d", i), firstVisited: Self.base,
                centerLatitude: athens.lat, centerLongitude: athens.lon))
        }
        try ctx.save()

        let gate = PipelineGate(forTesting: ())
        let fired = ProbeCounter()
        let (lat, lon, base) = (athens.lat, athens.lon, Self.base)
        AppDelegate.geocoderBackfillInterChunkProbe = { @Sendable in
            guard await fired.completions == 0 else { return }
            await fired.bump()
            await gate.run(touching: [.hexVisit]) {
                let context = ModelContext(container)
                let waiting = ((try? context.fetch(FetchDescriptor<HexVisit>(
                    predicate: #Predicate { $0.isoCountryCode == nil }))) ?? [])
                    .sorted { $0.h3Index < $1.h3Index }
                guard waiting.count == 2 else { return }
                // What the HexVisit ID repair does to a colliding row.
                waiting[0].id = UUID()
                // A different physical row now holds the other snapshot's UUID and cell.
                let replacement = HexVisit(
                    h3Index: waiting[1].h3Index, firstVisited: base,
                    centerLatitude: lat, centerLongitude: lon)
                replacement.id = waiting[1].id
                replacement.locality = "Replacement"
                context.delete(waiting[1])
                context.insert(replacement)
                try? context.save()
            }
        }
        defer { AppDelegate.geocoderBackfillInterChunkProbe = nil }

        let result = await AppDelegate.backfillOfflineGeocoder(modelContainer: container, gate: gate)

        #expect(await fired.completions == 1)
        #expect(result.saved)
        #expect(result.updatedHexVisits == total - 1, "the re-keyed row counts; the deleted one does not")
        let hexes = try ModelContext(container).fetch(FetchDescriptor<HexVisit>())
        #expect(hexes.count == total)
        let untouched = hexes.filter { $0.isoCountryCode == nil }
        #expect(untouched.count == 1, "only the replacement row stays unresolved")
        #expect(untouched.first?.locality == "Replacement")
    }
}
