//
//  GeocodeDrainOutcomeTests.swift
//  TravelLogTests
//
//  The geocode drain's per-unit contracts: every unit commits its Stay edits
//  with the parents' summaries (no whole-store tail), the HexVisit heal runs
//  in bounded self-gated units, a failed read or save is never reported as a
//  completed drain or latched by the activation token, and locality-nil stays
//  are drained even when no ping is pending. Resolvers are stubbed so results
//  never depend on Geocoder.sqlite being in the test host.
//

import Foundation
import os
import SwiftData
import Testing
@testable import TravelLog

private actor DrainUnitProbe {
    private(set) var observations: [Int] = []
    func observe(_ value: Int) { observations.append(value) }
}

@MainActor
@Suite("Geocode drain outcomes", .serialized, .timeLimit(.minutes(1)))
struct GeocodeDrainOutcomeTests {

    nonisolated static let base = Date(timeIntervalSince1970: 1_593_952_000)
    nonisolated private static let oceanBase = Date(timeIntervalSince1970: 1_600_000_000)
    nonisolated static let athensLatitude = 37.9838
    nonisolated static let athensLongitude = 23.7275

    nonisolated static let athens = GeocodeResolver.Result(
        country: "Greece", isoCountryCode: "GR", administrativeArea: "Attiki",
        metroName: nil, localityName: "Athens", subLocalityName: nil, islandName: nil)

    /// Athens for coordinates north of 10°, nothing for open ocean.
    nonisolated static func athensNorthOfTen(_ latitude: Double, _ longitude: Double) -> GeocodeResolver.Result? {
        latitude > 10 ? athens : nil
    }

    // MARK: - Seeding

    @discardableResult
    private func insertStay(
        _ context: ModelContext,
        latitude: Double = GeocodeDrainOutcomeTests.athensLatitude,
        longitude: Double = GeocodeDrainOutcomeTests.athensLongitude,
        start: Date = GeocodeDrainOutcomeTests.base,
        settled: Bool = true,
        pingIDs: [UUID] = [],
        inTrip: Bool = false
    ) throws -> Stay {
        let stay = Stay(
            startTime: start,
            endTime: settled ? start.addingTimeInterval(3_600) : Date.now,
            centroidLatitude: latitude,
            centroidLongitude: longitude,
            h3IndexRes6: try #require(H3Service.cellIndex(latitude: latitude, longitude: longitude)),
            pingCount: max(1, pingIDs.count),
            distanceFromHomeKm: 500,
            pingIDs: pingIDs)
        stay.category = .destination
        context.insert(stay)
        if inTrip {
            let trip = Trip(startDate: start)
            trip.endDate = stay.endTime
            context.insert(trip)
            trip.stays = [stay]
            trip.recomputeSummary()
        }
        return stay
    }

    private func insertUngeocodedPings(
        _ context: ModelContext, count: Int,
        latitude: Double = GeocodeDrainOutcomeTests.athensLatitude,
        longitude: Double = GeocodeDrainOutcomeTests.athensLongitude,
        start: Date = GeocodeDrainOutcomeTests.base
    ) throws -> [UUID] {
        let hex = try #require(H3Service.cellIndex(latitude: latitude, longitude: longitude))
        return (0..<count).map { i in
            let ping = LocationPing(
                timestamp: start.addingTimeInterval(Double(i)),
                latitude: latitude, longitude: longitude,
                horizontalAccuracy: 10, h3IndexRes6: hex)
            context.insert(ping)
            return ping.id
        }
    }

    /// A HexVisit that knows its place but not its ISO code, plus a geocoded donor ping.
    private func insertISOMissingHex(_ context: ModelContext, key: String, id: UUID? = nil) {
        let visit = HexVisit(h3Index: key, firstVisited: .distantPast,
            centerLatitude: Self.athensLatitude, centerLongitude: Self.athensLongitude)
        if let id { visit.id = id }
        visit.locality = "Athens"
        visit.country = "Greece"
        context.insert(visit)
        let donor = LocationPing(timestamp: Self.base, latitude: Self.athensLatitude,
            longitude: Self.athensLongitude, horizontalAccuracy: 10, h3IndexRes6: key)
        donor.isGeocoded = true
        donor.locality = "Athens"
        donor.country = "Greece"
        donor.isoCountryCode = "GR"
        context.insert(donor)
    }

    // MARK: - per-unit summaries and a bounded hex heal

    @Test("a drain interrupted after its first unit leaves the parent summary current")
    func interruptedDrainLeavesNoStaleSummary() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        _ = try insertUngeocodedPings(context, count: 10)
        let stay = try insertStay(context, inTrip: true)
        try context.save()
        #expect(stay.trip?.destinationSummary != "Athens")

        let recorder = PingRecorder(modelContainer: container)
        let answer = Self.athens
        await recorder.setHexResolverForTesting { _, _ in answer }
        // Cancelling here is what BG expiration or a thermal pause does after a unit commits.
        await recorder.setAfterHexPageForTesting {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let completed = await Task {
            await recorder.retryAllFailedGeocodingGated(gate: PipelineGate(forTesting: ()))
        }.value

        #expect(!completed)
        let fresh = ModelContext(container)
        let trip = try #require(try fresh.fetch(FetchDescriptor<Trip>()).first)
        #expect(trip.stays?.first?.locality == "Athens")
        #expect(trip.destinationSummary == "Athens")
        #expect(trip.countryCodes == "GR")
    }

    @Test("a summary an older drain left stale is caught up by the launch metro refresh")
    func staleSummaryWithoutGeocodeProgressIsCaughtUp() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        // An older drain committed the stay's place and expired before its parent refresh.
        let stay = try insertStay(context, inTrip: true)
        stay.locality = "Athens"
        stay.administrativeArea = "Attiki"
        stay.country = "Greece"
        stay.isoCountryCode = "GR"
        try context.save()
        #expect(stay.trip?.destinationSummary != "Athens")

        // Nothing is left to geocode, so no unit touches the parent.
        let recorder = PingRecorder(modelContainer: container)
        let completed = await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in nil }) {
            await recorder.retryAllFailedGeocodingGated(gate: PipelineGate(forTesting: ()))
        }
        #expect(completed)
        #expect(await recorder.takeGeocodeTripChange().isEmpty)

        // Devices that finished the pre-fix drains already latched the _v5 refresh.
        #expect(AppDelegate.tripSummaryMetroRefreshCompletedKey != "tripSummaryMetroRefreshCompleted_v5")
        let refresh = await AppDelegate.recomputeAllTripSummariesForMetroRefresh(modelContainer: container)
        #expect(refresh.saved)
        let trip = try #require(try ModelContext(container).fetch(FetchDescriptor<Trip>()).first)
        #expect(trip.destinationSummary == "Athens")
        #expect(trip.countryCodes == "GR")
    }

    @Test("the HexVisit heal commits bounded units a competing gate unit can pass between")
    func hexHealYieldsBetweenBoundedUnits() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        for i in 0..<120 { insertISOMissingHex(context, key: "hex-\(i)") }
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        let probe = DrainUnitProbe()
        await recorder.setAfterDrainUnitForTesting {
            await gate.run(touching: []) {
                let healed = await recorder.hexHealUnitRowsForTesting.reduce(0, +)
                await probe.observe(healed)
            }
        }
        let completed = await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in nil }) {
            await recorder.retryAllFailedGeocodingGated(gate: gate)
        }

        #expect(completed)
        #expect(await probe.observations == [50, 100, 120])
        #expect(try ModelContext(container).fetch(FetchDescriptor<HexVisit>())
            .allSatisfy { $0.isoCountryCode == "GR" })
    }

    @Test("a failed hex-heal unit keeps earlier units, rolls back its own and reports incomplete")
    func hexHealFailureAfterCommittedUnit() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        for i in 0..<60 { insertISOMissingHex(context, key: "hex-\(i)") }
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        await recorder.setAfterDrainUnitForTesting {
            await recorder.setGeocodeReadFaultForTesting(.hexDonor, enabled: true)
        }
        let outcome = await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in nil }) {
            await recorder.backfillHexVisitCountries(gate: PipelineGate(forTesting: ()))
        }

        #expect(outcome == PingRecorder.HexHealOutcome(healed: 50, completed: false))
        #expect(await recorder.hasPendingGeocodeChangesForTesting() == false)
        let rows = try ModelContext(container).fetch(FetchDescriptor<HexVisit>())
        #expect(rows.filter { $0.isoCountryCode == "GR" }.count == 50)
        #expect(rows.filter { $0.isoCountryCode == nil }.count == 10)
    }

    @Test("physical HexVisit twins selected by different gaps are both healed")
    func hexHealHealsPhysicalTwins() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let shared = UUID()
        // One twin misses only its ISO code, the other also misses its country.
        insertISOMissingHex(context, key: "hex-a", id: shared)
        let twin = HexVisit(h3Index: "hex-a", firstVisited: .distantPast,
            centerLatitude: Self.athensLatitude, centerLongitude: Self.athensLongitude)
        twin.id = shared
        twin.locality = "Athens"
        context.insert(twin)
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        let outcome = await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in nil }) {
            await recorder.backfillHexVisitCountries(gate: PipelineGate(forTesting: ()))
        }

        #expect(outcome == PingRecorder.HexHealOutcome(healed: 2, completed: true))
        let rows = try ModelContext(container).fetch(FetchDescriptor<HexVisit>())
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.country == "Greece" && $0.isoCountryCode == "GR" })
    }

    @Test("a drain with nothing to do dirties no trip")
    func noBacklogDrainDirtiesNothing() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let stay = try insertStay(context, inTrip: true)
        stay.locality = "Athens"
        stay.country = "Greece"
        stay.isoCountryCode = "GR"
        stay.trip?.recomputeSummary()
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        let completed = await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in nil }) {
            await recorder.retryAllFailedGeocodingGated(gate: PipelineGate(forTesting: ()))
        }
        #expect(completed)
        #expect(await recorder.takeGeocodeTripChange().isEmpty)
        #expect(await recorder.hasPendingGeocodeChangesForTesting() == false)
    }

    // MARK: - failures are not completion

    @Test("a failed page save ends the drain incomplete with nothing left pending")
    func failedSaveEndsDrainIncomplete() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        _ = try insertUngeocodedPings(context, count: 10)
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        let answer = Self.athens
        await recorder.setHexResolverForTesting { _, _ in answer }
        await recorder.setGeocodeSaveFailuresForTesting(1)
        let completed = await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in answer }) {
            await recorder.retryAllFailedGeocodingGated(gate: PipelineGate(forTesting: ()))
        }

        #expect(!completed)
        #expect(await recorder.hasPendingGeocodeChangesForTesting() == false)
        #expect(try ModelContext(container).fetch(FetchDescriptor<LocationPing>())
            .allSatisfy { !$0.isGeocoded })
    }

    @Test("a failed ping-ID read does not latch the unchanged backlog for this launch")
    func failedIDReadKeepsActivationRetryable() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        _ = try insertUngeocodedPings(context, count: 1)
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        // The hex centre misses, so only the per-ping phase can geocode this row.
        await recorder.setHexResolverForTesting { _, _ in nil }
        let gate = PipelineGate(forTesting: ())
        let answer = Self.athens
        await recorder.setGeocodeReadFaultForTesting(.ungeocodedPingIDs, enabled: true)
        await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in answer }) {
            await recorder.retryAllFailedGeocodingIfNeeded(gate: gate)
        }
        #expect(try ModelContext(container).fetch(FetchDescriptor<LocationPing>())
            .allSatisfy { !$0.isGeocoded })

        await recorder.setGeocodeReadFaultForTesting(.ungeocodedPingIDs, enabled: false)
        await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in answer }) {
            await recorder.retryAllFailedGeocodingIfNeeded(gate: gate)
        }
        #expect(try ModelContext(container).fetch(FetchDescriptor<LocationPing>())
            .allSatisfy { $0.isGeocoded && $0.locality == "Athens" })
    }

    @Test("a failed hex donor read leaves the heal retryable on the next activation")
    func failedHexDonorReadKeepsHealRetryable() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        insertISOMissingHex(context, key: "hex-a")
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        await recorder.setGeocodeReadFaultForTesting(.hexDonor, enabled: true)
        await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in nil }) {
            await recorder.retryAllFailedGeocodingIfNeeded(gate: gate)
        }
        #expect(try ModelContext(container).fetch(FetchDescriptor<HexVisit>())
            .first?.isoCountryCode == nil)
        #expect(await recorder.hasPendingGeocodeChangesForTesting() == false)

        await recorder.setGeocodeReadFaultForTesting(.hexDonor, enabled: false)
        await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in nil }) {
            await recorder.retryAllFailedGeocodingIfNeeded(gate: gate)
        }
        #expect(try ModelContext(container).fetch(FetchDescriptor<HexVisit>())
            .first?.isoCountryCode == "GR")
    }

    @Test("a failed propagation read rolls back the geocoded pings instead of saving them alone")
    func failedPropagationReadRollsBack() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let pingIDs = try insertUngeocodedPings(context, count: 1)
        try insertStay(context, pingIDs: pingIDs)
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        await recorder.setGeocodeReadFaultForTesting(.propagation, enabled: true)
        let answer = Self.athens
        let bite = await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in answer }) {
            await recorder.retryFailedGeocoding(limit: 10)
        }

        #expect(bite.failed)
        #expect(bite.progress == 0)
        #expect(await recorder.hasPendingGeocodeChangesForTesting() == false)
        let fresh = ModelContext(container)
        #expect(try fresh.fetch(FetchDescriptor<LocationPing>()).allSatisfy { !$0.isGeocoded })
        #expect(try fresh.fetch(FetchDescriptor<Stay>()).first?.locality == nil)
    }

    @Test("an unresolvable backlog still completes and terminates")
    func unresolvableBacklogCompletes() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        _ = try insertUngeocodedPings(context, count: 3, latitude: 0, longitude: -140, start: Self.oceanBase)
        try insertStay(context, latitude: 0, longitude: -140, start: Self.oceanBase)
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        await recorder.setHexResolverForTesting { _, _ in nil }
        let completed = await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in nil }) {
            await recorder.retryAllFailedGeocodingGated(gate: PipelineGate(forTesting: ()))
        }
        #expect(completed)
    }

    // MARK: - stay-only backlog

    @Test("a stay-only backlog is geocoded and its parent summary updated")
    func stayOnlyBacklogIsDrained() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        try insertStay(context, inTrip: true)
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        let answer = Self.athens
        let completed = await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in answer }) {
            await recorder.retryAllFailedGeocodingGated(gate: PipelineGate(forTesting: ()))
        }

        #expect(completed)
        let trip = try #require(try ModelContext(container).fetch(FetchDescriptor<Trip>()).first)
        #expect(trip.stays?.first?.locality == "Athens")
        #expect(trip.destinationSummary == "Athens")
        #expect(trip.countryCodes == "GR")
    }

    @Test("the refresh bite geocodes a stay when no ping is pending")
    func refreshBiteHealsStayWithoutPings() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        try insertStay(context)
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        let answer = Self.athens
        let bite = await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in answer }) {
            await recorder.retryFailedGeocoding(limit: 10)
        }

        #expect(bite.progress == 1)
        #expect(!bite.failed)
        #expect(try ModelContext(container).fetch(FetchDescriptor<Stay>()).first?.locality == "Athens")
    }

    @Test("a settled stay that moves into a resolvable area triggers the next activation drain")
    func movedStayRetriggersActivationDrain() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        try insertStay(context, latitude: 0, longitude: -160)
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        await GeocodeResolver.TestHook.$resolve.withValue({ Self.athensNorthOfTen($0, $1) }) {
            await recorder.retryAllFailedGeocodingIfNeeded(gate: gate)
        }
        #expect(try ModelContext(container).fetch(FetchDescriptor<Stay>()).first?.locality == nil)

        // Another writer moves the same row; its count and start time do not change.
        let mover = ModelContext(container)
        let row = try #require(try mover.fetch(FetchDescriptor<Stay>()).first)
        row.centroidLatitude = Self.athensLatitude
        row.centroidLongitude = Self.athensLongitude
        try mover.save()

        await GeocodeResolver.TestHook.$resolve.withValue({ Self.athensNorthOfTen($0, $1) }) {
            await recorder.retryAllFailedGeocodingIfNeeded(gate: gate)
        }
        #expect(try ModelContext(container).fetch(FetchDescriptor<Stay>()).first?.locality == "Athens")
    }

    @Test("an excluded stay that moves inside its cell triggers the next activation drain")
    func excludedStayMovedInsideItsCellRetriggersDrain() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        try insertStay(context, latitude: 0, longitude: -160, start: Self.oceanBase)
        try context.save()
        #expect(MapKitLocalityCache.cellKey(latitude: 0.000001, longitude: -160)
            == MapKitLocalityCache.cellKey(latitude: 0, longitude: -160))

        let recorder = PingRecorder(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        let resolutions = OSAllocatedUnfairLock(initialState: 0)
        let answer = Self.athens
        func activate() async {
            // A boundary inside the cell: only the moved centroid resolves.
            await GeocodeResolver.TestHook.$resolve.withValue({ latitude, _ in
                resolutions.withLock { $0 += 1 }
                return latitude == 0.000001 ? answer : nil
            }) {
                await recorder.retryAllFailedGeocodingIfNeeded(gate: gate)
            }
        }

        await activate()
        await activate()
        await activate()
        #expect(resolutions.withLock { $0 } == 1, "the settled no-result stay is tried once, then excluded")

        let mover = ModelContext(container)
        let row = try #require(try mover.fetch(FetchDescriptor<Stay>()).first)
        row.centroidLatitude = 0.000001
        try mover.save()
        await activate()
        #expect(resolutions.withLock { $0 } == 2)
        #expect(try ModelContext(container).fetch(FetchDescriptor<Stay>()).first?.locality == "Athens")
    }

    @Test("an ongoing stay drifting inside its cell skips the drain; a cell change reruns only the stay phase")
    func driftingStayDoesNotRerunWholeDrain() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        // A permanent backlog in every phase: an at-sea ping, an unresolvable hex and an
        // ongoing at-sea stay whose running-mean centroid keeps moving.
        _ = try insertUngeocodedPings(context, count: 1, latitude: 0, longitude: -140, start: Self.oceanBase)
        context.insert(HexVisit(h3Index: "hex-sea", firstVisited: .distantPast,
            centerLatitude: 0, centerLongitude: -120))
        try insertStay(context, latitude: 0, longitude: -160, start: Self.oceanBase, settled: false)
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        let hexCenters = OSAllocatedUnfairLock(initialState: 0)
        await recorder.setHexResolverForTesting { _, _ in
            hexCenters.withLock { $0 += 1 }
            return nil
        }
        let gate = PipelineGate(forTesting: ())
        // Longitudes separate the phases: ping -140, hex heal -120, stay -160.
        let resolved = OSAllocatedUnfairLock(initialState: [Double]())
        func activate() async -> (resolved: [Double], hexCenters: Int) {
            resolved.withLock { $0 = [] }
            hexCenters.withLock { $0 = 0 }
            await GeocodeResolver.TestHook.$resolve.withValue({ _, longitude in
                resolved.withLock { $0.append(longitude) }
                return nil
            }) {
                await recorder.retryAllFailedGeocodingIfNeeded(gate: gate)
            }
            return (resolved.withLock { $0 }, hexCenters.withLock { $0 })
        }
        func moveStay(toLatitude latitude: Double) throws {
            let mover = ModelContext(container)
            let row = try #require(try mover.fetch(FetchDescriptor<Stay>()).first)
            row.centroidLatitude = latitude
            try mover.save()
        }

        let first = await activate()
        #expect(Set(first.resolved) == [-140, -120, -160])
        #expect(first.hexCenters > 0)

        // Foreground pings move the centroid a few centimetres, inside the same res-8 cell.
        #expect(MapKitLocalityCache.cellKey(latitude: 0.000001, longitude: -160)
            == MapKitLocalityCache.cellKey(latitude: 0, longitude: -160))
        try moveStay(toLatitude: 0.000001)
        let drifted = await activate()
        #expect(drifted.resolved.isEmpty, "drift inside a cell must not rerun any phase")
        #expect(drifted.hexCenters == 0)

        // A move into another cell retries the stay alone; the ping and hex inputs are unchanged.
        #expect(MapKitLocalityCache.cellKey(latitude: 0.03, longitude: -160)
            != MapKitLocalityCache.cellKey(latitude: 0, longitude: -160))
        try moveStay(toLatitude: 0.03)
        let moved = await activate()
        #expect(moved.resolved == [-160])
        #expect(moved.hexCenters == 0)

        // That stay-only pass latched its token.
        let settled = await activate()
        #expect(settled.resolved.isEmpty)
        #expect(settled.hexCenters == 0)
    }

    @Test("each stay is attempted once per drain in bounded units")
    func stayPhaseAttemptsEachStayOncePerDrain() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        for i in 0..<120 {
            // Unsettled no-result stays stay retryable, so only the drain's own bound ends them.
            try insertStay(context, latitude: 0, longitude: -160,
                start: Self.oceanBase.addingTimeInterval(Double(i) * 7_200), settled: false)
        }
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        let probe = DrainUnitProbe()
        await recorder.setAfterDrainUnitForTesting { await probe.observe(1) }
        let resolutions = OSAllocatedUnfairLock(initialState: 0)
        let completed = await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in
            resolutions.withLock { $0 += 1 }
            return nil
        }) {
            await recorder.retryAllFailedGeocodingGated(gate: PipelineGate(forTesting: ()))
        }

        #expect(completed)
        #expect(resolutions.withLock { $0 } == 120)
        #expect(await probe.observations.count == 3)
    }

    @Test("stays an earlier drain excluded cost a later drain no unit")
    func excludedStaysCostLaterDrainNoUnit() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        for i in 0..<120 {
            try insertStay(context, latitude: 0, longitude: -160,
                start: Self.oceanBase.addingTimeInterval(Double(i) * 7_200))
        }
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        let probe = DrainUnitProbe()
        await recorder.setAfterDrainUnitForTesting { await probe.observe(1) }
        let resolutions = OSAllocatedUnfairLock(initialState: 0)
        func drain() async -> Bool {
            await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in
                resolutions.withLock { $0 += 1 }
                return nil
            }) {
                await recorder.retryAllFailedGeocodingGated(gate: PipelineGate(forTesting: ()))
            }
        }
        #expect(await drain())
        #expect(resolutions.withLock { $0 } == 120)
        #expect(await probe.observations.count == 3)

        // The settled no-result backlog stays excluded at its unchanged centroids.
        try insertStay(context, latitude: 0, longitude: -160, start: Self.oceanBase.addingTimeInterval(-7_200))
        try context.save()
        #expect(await drain())
        #expect(resolutions.withLock { $0 } == 121)
        #expect(await probe.observations.count == 4, "one unit for the one eligible stay")
    }

    @Test("physical stay twins sharing a UUID are attempted independently")
    func stayTwinsAreAttemptedIndependently() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let first = try insertStay(context)
        let second = try insertStay(context, start: Self.base.addingTimeInterval(7_200))
        second.id = first.id
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        let answer = Self.athens
        let completed = await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in answer }) {
            await recorder.retryAllFailedGeocodingGated(gate: PipelineGate(forTesting: ()))
        }

        #expect(completed)
        let stays = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        #expect(stays.count == 2)
        #expect(stays.allSatisfy { $0.locality == "Athens" })
    }
}

// MARK: - Geocode progress is a change, not a state

//  `geocodeUngeocodedStays` measured progress by the stay's post-write
//  STATE (`locality != nil || country != nil`) while its fetch predicate
//  selects on `locality == nil`. A coordinate resolving to country-without-
//  locality therefore counted as progress on EVERY pass forever while never
//  leaving the selection set and never reaching the unresolvable-exclusion
//  arm - voiding the drain loop's `passGeocoded == 0` termination guard.
extension GeocodeDrainOutcomeTests {

    private func stayOutcome(
        current: PingRecorder.StayPlaceFields,
        locality: String? = nil,
        country: String? = nil,
        iso: String? = nil,
        admin: String? = nil,
        settled: Bool
    ) -> PingRecorder.StayGeocodeOutcome {
        PingRecorder.stayGeocodeOutcome(
            current: current,
            resolvedLocality: locality,
            resolvedCountry: country,
            resolvedISOCountryCode: iso,
            resolvedAdministrativeArea: admin,
            stayHasSettled: settled
        )
    }

    /// The phantom-progress shape, pinned at the DECISION rather than at the
    /// merge helper: the stay was country-stamped on an earlier pass, its
    /// locality is still nil (so the `locality == nil` fetch predicate keeps
    /// re-selecting it), and the resolver again answers country-without-
    /// locality. The pre-fix rule called this progress on every pass forever
    /// AND never reached the exclusion arm; both halves are pinned here.
    @Test("A country-only re-resolve of an already-stamped settled stay is exhausted, not progress")
    func countryOnlyReresolveIsExhausted() {
        let current = PingRecorder.StayPlaceFields(
            locality: nil,
            country: "Greece",
            isoCountryCode: "GR",
            administrativeArea: "North Aegean"
        )
        let result = stayOutcome(
            current: current,
            country: "Greece",
            iso: "GR",
            admin: "North Aegean",
            settled: true
        )
        #expect(result == .exhausted)
        // Explicitly: it must NOT be a progress outcome, because that return
        // value is the drain loop's only termination oracle.
        if case .progressed = result {
            Issue.record("country-only re-resolve must never count as drain progress")
        }
    }

    @Test("An unsettled no-gain stay retries later but still reports no progress")
    func unsettledNoGainRetriesWithoutProgress() {
        let current = PingRecorder.StayPlaceFields(
            locality: nil, country: "Greece", isoCountryCode: "GR", administrativeArea: nil
        )
        // Recent stay: its running centroid may still drift into a city
        // polygon, so it must stay retryable - but it is not progress.
        let result = stayOutcome(current: current, country: "Greece", iso: "GR", settled: false)
        #expect(result == .retryLater)
    }

    @Test("A genuine first country hit counts as progress")
    func firstCountryHitIsProgress() {
        let current = PingRecorder.StayPlaceFields(
            locality: nil, country: nil, isoCountryCode: nil, administrativeArea: nil
        )
        let result = stayOutcome(current: current, country: "Greece", iso: "GR", settled: true)
        #expect(result == .progressed(PingRecorder.StayPlaceFields(
            locality: nil, country: "Greece", isoCountryCode: "GR", administrativeArea: nil
        )))
    }

    @Test("A later locality hit counts as progress")
    func lateLocalityHitIsProgress() {
        let current = PingRecorder.StayPlaceFields(
            locality: nil, country: "Greece", isoCountryCode: "GR", administrativeArea: nil
        )
        let result = stayOutcome(
            current: current, locality: "Kontakaíika", country: "Greece", iso: "GR", settled: true
        )
        #expect(result == .progressed(PingRecorder.StayPlaceFields(
            locality: "Kontakaíika", country: "Greece", isoCountryCode: "GR", administrativeArea: nil
        )))
    }

    @Test("An island-only hit that would wipe country is not progress")
    func islandOnlyHitDoesNotWipeOrProgress() {
        let current = PingRecorder.StayPlaceFields(
            locality: "Kontakaíika",
            country: "Greece",
            isoCountryCode: "GR",
            administrativeArea: "North Aegean"
        )
        // Resolver answers with nothing storable: coalesce must keep every
        // field, and "no gain" must not masquerade as progress.
        let result = stayOutcome(current: current, settled: true)
        #expect(result == .exhausted)
    }

    @Test("Coalesce never wipes a non-nil field with nil")
    func coalesceNeverWipes() {
        let stay = PingRecorder.StayPlaceFields(
            locality: "Kontakaíika",
            country: "Greece",
            isoCountryCode: "GR",
            administrativeArea: "North Aegean"
        )
        // An island-only resolver hit carries nil country/ISO.
        let after = stay.coalescing(
            locality: nil, country: nil, isoCountryCode: nil, administrativeArea: nil
        )
        #expect(after == stay)
        #expect(after.country == "Greece")
        #expect(after.isoCountryCode == "GR")
        #expect(after.administrativeArea == "North Aegean")
    }
}
