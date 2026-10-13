import Testing
import Foundation
import SwiftData
import os
@testable import TravelLog

@Suite(.serialized)
@MainActor
struct StayClustererLocalityEnrichmentTests {
    nonisolated static func result(_ locality: String? = nil) -> GeocodeResolver.Result {
        GeocodeResolver.Result(country: "Greece", isoCountryCode: "GR",
            administrativeArea: "Attiki", metroName: nil, localityName: locality,
            subLocalityName: nil, islandName: nil)
    }

    private func fixture() throws -> ModelContainer {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(LocationPing(timestamp: Date(timeIntervalSince1970: 1_723_587_200),
            latitude: 37.9468, longitude: 23.7194, horizontalAccuracy: 10,
            h3IndexRes6: H3Service.cellIndex(latitude: 37.9468, longitude: 23.7194)!,
            source: .liveSLC))
        try context.save()
        return container
    }

    @Test func clusteringLeavesMissingLocalityForPostGateEnrichment() async throws {
        let container = try fixture()
        let clusterer = StayClusterer(modelContainer: container)
        try await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in Self.result() }) {
            try await MapKitLocalityCache.TestHook.$enrich.withValue({ _, _, _, allowWait in
                #expect(!allowWait)
                return Self.result("Stub MapKit Town")
            }) {
                let outcome = await PipelineGate.shared.runReturning(touching: []) {
                    await clusterer.clusterUnprocessedPingsReportingChanges()
                }
                let stay = try #require(ModelContext(container).fetch(FetchDescriptor<Stay>()).first)
                #expect(stay.locality == nil)
                #expect(outcome.created == 1 && outcome.needsPublication)
                #expect(outcome.pendingLocalities.candidates.map(\.id) == [stay.id])
                #expect(outcome.pendingLocalities.candidates.first?.latitude == 37.9468)
                #expect(outcome.pendingLocalities.candidates.first?.longitude == 23.7194)
                #expect(await clusterer.enrichPendingLocalities(outcome.pendingLocalities))
                let enriched = try #require(ModelContext(container).fetch(FetchDescriptor<Stay>()).first)
                #expect(enriched.locality == "Stub MapKit Town")
                #expect(enriched.country == "Greece")
                #expect(enriched.administrativeArea == "Attiki")
                #expect(enriched.isoCountryCode == "GR")
            }
        }
    }

    @Test func enrichmentInvalidatesTitleOfAlreadyClassifiedStay() async throws {
        let container = try fixture()
        let clusterer = StayClusterer(modelContainer: container)
        try await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in Self.result() }) {
            try await MapKitLocalityCache.TestHook.$enrich.withValue({ _, _, _, _ in
                Self.result("Stub MapKit Town")
            }) {
                let outcome = await PipelineGate.shared.runReturning(touching: []) {
                    await clusterer.clusterUnprocessedPingsReportingChanges()
                }
                // A concurrent pass classifies and titles the stay before enrichment applies.
                let setup = ModelContext(container)
                let stay = try #require(setup.fetch(FetchDescriptor<Stay>()).first)
                stay.category = .destination
                let trip = Trip(startDate: stay.startTime)
                trip.endDate = stay.endTime
                trip.aiGeneratedTitle = "Stale title"
                setup.insert(trip)
                trip.stays = [stay]
                trip.recomputeSummary()
                try setup.save()
                #expect(trip.destinationSummary != "Stub MapKit Town")

                #expect(await clusterer.enrichPendingLocalities(outcome.pendingLocalities))
                let check = ModelContext(container)
                let enrichedTrip = try #require(check.fetch(FetchDescriptor<Trip>()).first)
                #expect(enrichedTrip.aiGeneratedTitle == nil)
                #expect(enrichedTrip.destinationSummary == "Stub MapKit Town")
                #expect(enrichedTrip.stays?.first?.locality == "Stub MapKit Town")
            }
        }
    }

    @Test func enrichmentDoesNotResurrectDeletedStay() async throws {
        let container = try fixture()
        let clusterer = StayClusterer(modelContainer: container)
        try await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in Self.result() }) {
            let outcome = await PipelineGate.shared.runReturning(touching: []) {
                await clusterer.clusterUnprocessedPingsReportingChanges()
            }
            #expect(outcome.pendingLocalities.candidates.count == 1)
            await MapKitLocalityCache.TestHook.$enrich.withValue({ _, _, _, _ in
                await PipelineGate.shared.run(touching: []) {
                    await MainActor.run {
                        let context = ModelContext(container)
                        for stay in try! context.fetch(FetchDescriptor<Stay>()) { context.delete(stay) }
                        try! context.save()
                    }
                }
                return Self.result("Too Late")
            }) {
                #expect(await clusterer.enrichPendingLocalities(outcome.pendingLocalities) == false)
            }
            let remaining = try ModelContext(container).fetchCount(FetchDescriptor<Stay>())
            #expect(remaining == 0)
        }
    }

    @Test func enrichmentSkipsStayThatMovedToAnotherCell() async throws {
        let container = try fixture()
        let clusterer = StayClusterer(modelContainer: container)
        try await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in Self.result() }) {
            let outcome = await PipelineGate.shared.runReturning(touching: []) {
                await clusterer.clusterUnprocessedPingsReportingChanges()
            }
            #expect(outcome.pendingLocalities.candidates.count == 1)
            #expect(MapKitLocalityCache.cellKey(latitude: 37.9468, longitude: 23.7194)
                != MapKitLocalityCache.cellKey(latitude: 37.9668, longitude: 23.7194))
            // Later pings extend the stay into the next res-8 cell before enrichment applies.
            let mover = ModelContext(container)
            let stay = try #require(mover.fetch(FetchDescriptor<Stay>()).first)
            stay.centroidLatitude = 37.9668
            try mover.save()
            // Only the old cell has a name; the follow-up lookup at the new centroid is nameless.
            let oldCell = MapKitLocalityCache.cellKey(latitude: 37.9468, longitude: 23.7194)
            let probe = LocalityRequestProbe()
            await MapKitLocalityCache.TestHook.$enrich.withValue({ offline, latitude, longitude, _ in
                await probe.start()
                return MapKitLocalityCache.cellKey(latitude: latitude, longitude: longitude) == oldCell
                    ? Self.result("Old Cell Town") : offline
            }) {
                #expect(await clusterer.enrichPendingLocalities(outcome.pendingLocalities) == false)
            }
            #expect(await probe.calls == 2)
            let check = try #require(ModelContext(container).fetch(FetchDescriptor<Stay>()).first)
            #expect(check.locality == nil)
        }
    }

    /// The name answered for a cell, so a test can tell which centroid a lookup used.
    nonisolated static func town(latitude: Double, longitude: Double) -> String {
        "Town " + MapKitLocalityCache.cellKey(latitude: latitude, longitude: longitude)
    }

    @Test func enrichmentRecoversStayThatMovedBeforeApply() async throws {
        let container = try fixture()
        let clusterer = StayClusterer(modelContainer: container)
        try await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in Self.result() }) {
            let outcome = await PipelineGate.shared.runReturning(touching: []) {
                await clusterer.clusterUnprocessedPingsReportingChanges()
            }
            #expect(outcome.pendingLocalities.candidates.count == 1)
            // A later clustering run extends the stay into the next res-8 cell while
            // the first lookup is open; the caller supplies no other candidate.
            let moved = OSAllocatedUnfairLock(initialState: false)
            await MapKitLocalityCache.TestHook.$enrich.withValue({ _, latitude, longitude, _ in
                if moved.withLock({ state -> Bool in let first = !state; state = true; return first }) {
                    await PipelineGate.shared.run(touching: []) {
                        await MainActor.run {
                            let context = ModelContext(container)
                            let stay = try! context.fetch(FetchDescriptor<Stay>()).first!
                            stay.centroidLatitude = 37.9668
                            try! context.save()
                        }
                    }
                }
                return Self.result(Self.town(latitude: latitude, longitude: longitude))
            }) {
                #expect(await clusterer.enrichPendingLocalities(outcome.pendingLocalities))
            }
            let check = try #require(ModelContext(container).fetch(FetchDescriptor<Stay>()).first)
            #expect(check.locality == Self.town(latitude: 37.9668, longitude: 23.7194))
            #expect(check.locality != Self.town(latitude: 37.9468, longitude: 23.7194))
        }
    }

    @Test func stayStillMovingIsCarriedToNextCall() async throws {
        let container = try fixture()
        let clusterer = StayClusterer(modelContainer: container)
        let cells = [37.9468, 37.9668, 37.9868].map {
            MapKitLocalityCache.cellKey(latitude: $0, longitude: 23.7194)
        }
        #expect(Set(cells).count == 3)
        try await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in Self.result() }) {
            let outcome = await PipelineGate.shared.runReturning(touching: []) {
                await clusterer.clusterUnprocessedPingsReportingChanges()
            }
            #expect(outcome.pendingLocalities.candidates.count == 1)
            // Each of the first two lookups sees the stay move on before its apply.
            let moves = OSAllocatedUnfairLock(initialState: [37.9668, 37.9868])
            try await MapKitLocalityCache.TestHook.$enrich.withValue({ _, latitude, longitude, _ in
                let next: Double? = moves.withLock { $0.isEmpty ? nil : $0.removeFirst() }
                if let next {
                    await PipelineGate.shared.run(touching: []) {
                        await MainActor.run {
                            let context = ModelContext(container)
                            let stay = try! context.fetch(FetchDescriptor<Stay>()).first!
                            stay.centroidLatitude = next
                            try! context.save()
                        }
                    }
                }
                return Self.result(Self.town(latitude: latitude, longitude: longitude))
            }) {
                #expect(await clusterer.enrichPendingLocalities(outcome.pendingLocalities) == false)
                let unnamed = try #require(ModelContext(container).fetch(FetchDescriptor<Stay>()).first)
                #expect(unnamed.locality == nil)
                // The next pipeline call has no new candidate of its own.
                #expect(await clusterer.enrichPendingLocalities(.empty))
            }
            let check = try #require(ModelContext(container).fetch(FetchDescriptor<Stay>()).first)
            #expect(check.locality == Self.town(latitude: 37.9868, longitude: 23.7194))
        }
    }

    private func wipeDefaults() throws -> (UserDefaults, String) {
        let suite = "stay-enrichment-wipe-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    /// The Settings wipe unit's body against the fixture store and a throwaway defaults suite.
    private static func deleteAllData(_ container: ModelContainer, defaults: UserDefaults) -> Bool {
        DataWipe.execute(
            container: container, defaults: defaults,
            clearDissolvedQueue: {},
            obsoleteStoreFamily: { _ in nil })
    }

    @Test func deleteAllDataRevokesCarriedCandidates() async throws {
        let (defaults, suite) = try wipeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try fixture()
        let clusterer = StayClusterer(modelContainer: container)
        let probe = LocalityRequestProbe()
        try await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in Self.result() }) {
            let outcome = await PipelineGate.shared.runReturning(touching: []) {
                await clusterer.clusterUnprocessedPingsReportingChanges(defaults: UserDefaults(suiteName: suite)!)
            }
            #expect(outcome.pendingLocalities.candidates.count == 1)
            // Each of the two lookups sees the stay move on before its apply, so the call
            // carries the stay's centroid into the clusterer's next call.
            let moves = OSAllocatedUnfairLock(initialState: [37.9668, 37.9868])
            try await MapKitLocalityCache.TestHook.$enrich.withValue({ _, latitude, longitude, _ in
                await probe.start()
                let next: Double? = moves.withLock { $0.isEmpty ? nil : $0.removeFirst() }
                if let next {
                    await PipelineGate.shared.run(touching: []) {
                        await MainActor.run {
                            let context = ModelContext(container)
                            let stay = try! context.fetch(FetchDescriptor<Stay>()).first!
                            stay.centroidLatitude = next
                            try! context.save()
                        }
                    }
                }
                return Self.result(Self.town(latitude: latitude, longitude: longitude))
            }) {
                #expect(await clusterer.enrichPendingLocalities(
                    outcome.pendingLocalities, defaults: UserDefaults(suiteName: suite)!) == false)
                #expect(await probe.calls == 2)

                #expect(Self.deleteAllData(container, defaults: defaults))
                let remainingStays = try ModelContext(container).fetchCount(FetchDescriptor<Stay>())
                #expect(remainingStays == 0)
                // The next pipeline call after the wipe has no candidate of its own.
                #expect(await clusterer.enrichPendingLocalities(.empty, defaults: UserDefaults(suiteName: suite)!) == false)
            }
        }
        #expect(await probe.calls == 2, "a carried pre-wipe centroid must never be looked up after the wipe")
    }

    @Test func deleteAllDataDuringLookupStopsTheCall() async throws {
        let (defaults, suite) = try wipeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try fixture()
        let clusterer = StayClusterer(modelContainer: container)
        let probe = LocalityRequestProbe()
        try await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in Self.result() }) {
            let outcome = await PipelineGate.shared.runReturning(touching: []) {
                await clusterer.clusterUnprocessedPingsReportingChanges(defaults: UserDefaults(suiteName: suite)!)
            }
            let first = try #require(outcome.pendingLocalities.candidates.first)
            // A second pending stay in another cell, from the same pipeline pass.
            let setup = ModelContext(container)
            let north = Stay(
                startTime: Date(timeIntervalSince1970: 1_723_687_200),
                endTime: Date(timeIntervalSince1970: 1_723_690_800),
                centroidLatitude: 37.9868, centroidLongitude: 23.7194,
                h3IndexRes6: try #require(H3Service.cellIndex(latitude: 37.9868, longitude: 23.7194)),
                pingCount: 1, distanceFromHomeKm: 500, pingIDs: [])
            setup.insert(north)
            try setup.save()
            #expect(MapKitLocalityCache.cellKey(latitude: first.latitude, longitude: first.longitude)
                != MapKitLocalityCache.cellKey(latitude: 37.9868, longitude: 23.7194))
            var pending = outcome.pendingLocalities
            pending.candidates.append((north.id, 37.9868, 23.7194))
            // Delete All Data commits while the first lookup is open.
            await MapKitLocalityCache.TestHook.$enrich.withValue({ _, latitude, longitude, _ in
                await probe.start()
                await PipelineGate.shared.run(touching: []) {
                    await MainActor.run {
                        _ = Self.deleteAllData(container, defaults: UserDefaults(suiteName: suite)!)
                    }
                }
                return Self.result(Self.town(latitude: latitude, longitude: longitude))
            }) {
                #expect(await clusterer.enrichPendingLocalities(pending, defaults: UserDefaults(suiteName: suite)!) == false)
                #expect(await probe.calls == 1, "no pre-wipe centroid is looked up once the wipe commits")
                #expect(await clusterer.enrichPendingLocalities(.empty, defaults: UserDefaults(suiteName: suite)!) == false)
            }
        }
        #expect(await probe.calls == 1, "nothing the stopped call held is carried past the wipe")
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Stay>()) == 0)
    }

    @Test func deleteAllDataBeforeEnrichmentStartsRevokesTheClusteredBatch() async throws {
        let (defaults, suite) = try wipeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try fixture()
        let clusterer = StayClusterer(modelContainer: container)
        let probe = LocalityRequestProbe()
        let offlineLookups = OSAllocatedUnfairLock(initialState: 0)
        await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in
            offlineLookups.withLock { $0 += 1 }
            return Self.result()
        }) {
            let outcome = await PipelineGate.shared.runReturning(touching: []) {
                await clusterer.clusterUnprocessedPingsReportingChanges(defaults: UserDefaults(suiteName: suite)!)
            }
            #expect(outcome.pendingLocalities.candidates.count == 1)
            let clusteringLookups = offlineLookups.withLock { $0 }
            // Delete All Data commits after the clustering unit returns, before its caller enriches.
            let wiped = await PipelineGate.shared.runReturning(touching: []) {
                await MainActor.run {
                    Self.deleteAllData(container, defaults: UserDefaults(suiteName: suite)!)
                }
            }
            #expect(wiped)
            await MapKitLocalityCache.TestHook.$enrich.withValue({ offline, _, _, _ in
                await probe.start()
                return offline
            }) {
                #expect(await clusterer.enrichPendingLocalities(
                    outcome.pendingLocalities, defaults: UserDefaults(suiteName: suite)!) == false)
                #expect(await clusterer.enrichPendingLocalities(.empty, defaults: UserDefaults(suiteName: suite)!) == false)
            }
            #expect(offlineLookups.withLock { $0 } == clusteringLookups,
                    "a centroid clustered before the wipe is never resolved after it")
        }
        #expect(await probe.calls == 0, "a centroid clustered before the wipe never reaches MapKit")
    }

    @Test func namedEnrichmentAppliesEveryCandidateAcrossFetchSlices() async throws {
        let container = try fixture()
        let setup = ModelContext(container)
        let hex = try #require(H3Service.cellIndex(latitude: 37.9468, longitude: 23.7194))
        var pending: [StayClusterer.PendingLocality] = []
        // More candidates than one apply fetch matches, all in one named cell.
        for i in 0..<250 {
            let start = Date(timeIntervalSince1970: 1_723_687_200 + Double(i) * 7_200)
            let stay = Stay(startTime: start, endTime: start.addingTimeInterval(3_600),
                centroidLatitude: 37.9468, centroidLongitude: 23.7194, h3IndexRes6: hex,
                pingCount: 1, distanceFromHomeKm: 500, pingIDs: [])
            setup.insert(stay)
            pending.append((stay.id, 37.9468, 23.7194))
        }
        // A nameless candidate in another cell whose row moved again before the apply.
        let drifting = Stay(
            startTime: Date(timeIntervalSince1970: 1_623_587_200),
            endTime: Date(timeIntervalSince1970: 1_623_590_800),
            centroidLatitude: 38.0068, centroidLongitude: 23.7194,
            h3IndexRes6: try #require(H3Service.cellIndex(latitude: 38.0068, longitude: 23.7194)),
            pingCount: 1, distanceFromHomeKm: 500, pingIDs: [])
        setup.insert(drifting)
        try setup.save()
        pending.append((drifting.id, 37.9868, 23.7194))
        #expect(Set([37.9468, 37.9868, 38.0068].map {
            MapKitLocalityCache.cellKey(latitude: $0, longitude: 23.7194)
        }).count == 3)

        let clusterer = StayClusterer(modelContainer: container)
        let probe = LocalityRequestProbe()
        let namedCell = MapKitLocalityCache.cellKey(latitude: 37.9468, longitude: 23.7194)
        try await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in Self.result() }) {
            try await MapKitLocalityCache.TestHook.$enrich.withValue({ offline, latitude, longitude, _ in
                await probe.start()
                return MapKitLocalityCache.cellKey(latitude: latitude, longitude: longitude) == namedCell
                    ? Self.result("Sliced Town") : offline
            }) {
                #expect(await clusterer.enrichPendingLocalities(StayClusterer.PendingLocalities(
                    candidates: pending, wipeFloor: StayClusterer.wipeFloor(in: .standard))))
                // The named cell and the drifting row's first and follow-up cells.
                #expect(await probe.calls == 3)
                let stays = try ModelContext(container).fetch(FetchDescriptor<Stay>())
                #expect(stays.filter { $0.locality == "Sliced Town" }.count == 250)
                #expect(stays.first { $0.id == drifting.id }?.locality == nil)
            }
        }
    }

    @Test func clusteringEmitsFinalCentroidOfStayExtendedInSameBatch() async throws {
        let container = try fixture()
        let context = ModelContext(container)
        // A second ping 2.9 km north moves the new stay's centroid 1.4 km into another res-8 cell.
        context.insert(LocationPing(timestamp: Date(timeIntervalSince1970: 1_723_587_800),
            latitude: 37.9728, longitude: 23.7194, horizontalAccuracy: 10,
            h3IndexRes6: H3Service.cellIndex(latitude: 37.9728, longitude: 23.7194)!,
            source: .liveSLC))
        try context.save()
        let clusterer = StayClusterer(modelContainer: container)
        let probe = LocalityRequestProbe()
        try await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in Self.result() }) {
            try await MapKitLocalityCache.TestHook.$enrich.withValue({ _, latitude, longitude, _ in
                await probe.start()
                return Self.result(Self.town(latitude: latitude, longitude: longitude))
            }) {
                let outcome = await PipelineGate.shared.runReturning(touching: []) {
                    await clusterer.clusterUnprocessedPingsReportingChanges()
                }
                #expect(outcome.created == 1)
                let stay = try #require(ModelContext(container).fetch(FetchDescriptor<Stay>()).first)
                #expect(stay.pingCount == 2)
                let finalCell = MapKitLocalityCache.cellKey(
                    latitude: stay.centroidLatitude, longitude: stay.centroidLongitude)
                #expect(finalCell != MapKitLocalityCache.cellKey(latitude: 37.9468, longitude: 23.7194))
                let candidate = try #require(outcome.pendingLocalities.candidates.first)
                #expect(outcome.pendingLocalities.candidates.count == 1)
                #expect(candidate.latitude == stay.centroidLatitude)
                #expect(candidate.longitude == stay.centroidLongitude)
                #expect(await clusterer.enrichPendingLocalities(outcome.pendingLocalities))
                #expect(await probe.calls == 1)
                let enriched = try #require(ModelContext(container).fetch(FetchDescriptor<Stay>()).first)
                #expect(enriched.locality == "Town " + finalCell)
            }
        }
    }

    @Test func enrichmentPreservesLocalityWrittenDuringRequest() async throws {
        let container = try fixture()
        let clusterer = StayClusterer(modelContainer: container)
        try await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in Self.result() }) {
            let outcome = await PipelineGate.shared.runReturning(touching: []) {
                await clusterer.clusterUnprocessedPingsReportingChanges()
            }
            await MapKitLocalityCache.TestHook.$enrich.withValue({ _, _, _, _ in
                await PipelineGate.shared.run(touching: []) {
                    await MainActor.run {
                        let context = ModelContext(container)
                        let stay = try! context.fetch(FetchDescriptor<Stay>()).first!
                        stay.locality = "Drain Winner"
                        try! context.save()
                    }
                }
                return Self.result("Too Late")
            }) {
                #expect(await clusterer.enrichPendingLocalities(outcome.pendingLocalities) == false)
            }
            let stay = try #require(ModelContext(container).fetch(FetchDescriptor<Stay>()).first)
            #expect(stay.locality == "Drain Winner")
        }
    }

    /// The stubbed request is held open on a latch, so the oracle never races
    /// a timer against other suites holding the shared gate: a unit on that
    /// gate must complete while the request is still open, then the test
    /// releases the request. Enrichment inside the gate would deadlock here
    /// and trip the time limit. The flow is a child `Task` (not detached) so
    /// it inherits the task-local resolver and MapKit stubs.
    @Test(.timeLimit(.minutes(1)))
    func anotherGateUnitCompletesDuringOpenMapKitRequest() async throws {
        let container = try fixture()
        let clusterer = StayClusterer(modelContainer: container)
        let probe = LocalityRequestProbe()
        await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in Self.result() }) {
            await MapKitLocalityCache.TestHook.$enrich.withValue({ _, _, _, allowWait in
                #expect(!allowWait)
                await probe.start()
                await probe.holdUntilReleased()
                await probe.finish()
                return Self.result("Slow MapKit Town")
            }) {
                let flow = Task {
                    let outcome = await PipelineGate.shared.runReturning(touching: []) {
                        await clusterer.clusterUnprocessedPingsReportingChanges()
                    }
                    await clusterer.enrichPendingLocalities(outcome.pendingLocalities)
                }
                await probe.waitUntilStarted()
                let releasedDuringRequest = await PipelineGate.shared.runReturning(touching: []) {
                    !(await probe.finished)
                }
                #expect(releasedDuringRequest, "another gate unit completed while the MapKit request was open")
                await probe.release()
                await flow.value
            }
        }
    }

    @Test func visitAndPingStaysShareOneCellEnrichment() async throws {
        let container = try fixture()
        let context = ModelContext(container)
        let arrival = Date(timeIntervalSince1970: 1_723_587_200 + 2 * 86400)
        context.insert(Visit(arrivalDate: arrival, departureDate: arrival.addingTimeInterval(3600),
            latitude: 37.9468, longitude: 23.7194, horizontalAccuracy: 5,
            receivedAt: arrival.addingTimeInterval(3600)))
        try context.save()
        let clusterer = StayClusterer(modelContainer: container)
        let probe = LocalityRequestProbe()
        try await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in Self.result() }) {
            try await MapKitLocalityCache.TestHook.$enrich.withValue({ _, _, _, allowWait in
                #expect(!allowWait)
                await probe.start()
                return Self.result("Shared Cell Town")
            }) {
                let outcome = await PipelineGate.shared.runReturning(touching: []) {
                    await clusterer.clusterUnprocessedPingsReportingChanges()
                }
                #expect(outcome.created == 2)
                #expect(outcome.pendingLocalities.candidates.count == 2)
                #expect(await probe.calls == 0)
                #expect(await clusterer.enrichPendingLocalities(outcome.pendingLocalities))
                #expect(await probe.calls == 1)
                let stays = try ModelContext(container).fetch(FetchDescriptor<Stay>())
                #expect(stays.count == 2)
                #expect(stays.allSatisfy { $0.locality == "Shared Cell Town" })
                #expect(stays.contains { $0.pingCount == 0 })
            }
        }
    }

    @Test(arguments: ["nil", "country", "metro", "seed"])
    func onlyMissingOfflineNamesArePending(kind: String) async throws {
        let container = try fixture()
        if kind == "seed" {
            let context = ModelContext(container)
            let ping = try #require(context.fetch(FetchDescriptor<LocationPing>()).first)
            ping.locality = "Seed Town"
            try context.save()
        }
        let offline: GeocodeResolver.Result?
        switch kind {
        case "nil": offline = nil
        case "country": offline = Self.result("Greece")
        case "metro": offline = GeocodeResolver.Result(country: "Greece", isoCountryCode: "GR",
            administrativeArea: "Attiki", metroName: "Athens", localityName: nil,
            subLocalityName: nil, islandName: nil)
        default: offline = Self.result()
        }
        let clusterer = StayClusterer(modelContainer: container)
        try await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in offline }) {
            let outcome = await PipelineGate.shared.runReturning(touching: []) {
                await clusterer.clusterUnprocessedPingsReportingChanges()
            }
            #expect(outcome.pendingLocalities.candidates.isEmpty)
            let stay = try #require(ModelContext(container).fetch(FetchDescriptor<Stay>()).first)
            let expected = kind == "seed" ? "Seed Town" : offline?.localityForStorage
            #expect(stay.locality == expected)
        }
    }

    @Test func rolledBackPingSaveReturnsNoPendingLocalities() async throws {
        let container = try fixture()
        let clusterer = StayClusterer(modelContainer: container)
        await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in Self.result() }) {
            let outcome = await PipelineGate.shared.runReturning(touching: []) {
                await clusterer.clusterUnprocessedPingsReportingChanges(beforeSave: {
                    throw CocoaError(.fileWriteUnknown)
                })
            }
            #expect(outcome.created == 0)
            #expect(outcome.needsPublication)
            #expect(outcome.pendingLocalities.candidates.isEmpty)
        }
    }

    @Test func visitRollbackRetainsOnlyCommittedPingEnrichment() async throws {
        let container = try fixture()
        let context = ModelContext(container)
        let arrival = Date(timeIntervalSince1970: 1_723_587_200 + 2 * 86400)
        context.insert(Visit(arrivalDate: arrival, departureDate: arrival.addingTimeInterval(3600),
            latitude: 37.9468, longitude: 23.7194, horizontalAccuracy: 5,
            receivedAt: arrival.addingTimeInterval(3600)))
        try context.save()
        let clusterer = StayClusterer(modelContainer: container)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        try await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in Self.result() }) {
            let outcome = await PipelineGate.shared.runReturning(touching: []) {
                await clusterer.clusterUnprocessedPingsReportingChanges(beforeSave: {
                    let count = calls.withLock { $0 += 1; return $0 }
                    if count == 2 { throw CocoaError(.fileWriteUnknown) }
                })
            }
            #expect(outcome.created == 1)
            #expect(outcome.needsPublication)
            #expect(outcome.pendingLocalities.candidates.count == 1)
            let stays = try ModelContext(container).fetch(FetchDescriptor<Stay>())
            #expect(stays.map(\.id) == outcome.pendingLocalities.candidates.map(\.id))
        }
    }

    @Test func namelessEnrichmentAttemptsEachCellOnce() async throws {
        let container = try fixture()
        let clusterer = StayClusterer(modelContainer: container)
        let probe = LocalityRequestProbe()
        await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in Self.result() }) {
            await MapKitLocalityCache.TestHook.$enrich.withValue({ offline, _, _, _ in
                await probe.start()
                return offline
            }) {
                let outcome = await PipelineGate.shared.runReturning(touching: []) {
                    await clusterer.clusterUnprocessedPingsReportingChanges()
                }
                var doubled = outcome.pendingLocalities
                doubled.candidates += doubled.candidates
                #expect(await clusterer.enrichPendingLocalities(doubled) == false)
                #expect(await probe.calls == 1)
            }
        }
    }

}

private actor LocalityRequestProbe {
    private(set) var started = false
    private(set) var finished = false
    private(set) var calls = 0
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func start() {
        started = true
        calls += 1
        for waiter in startWaiters { waiter.resume() }
        startWaiters.removeAll()
    }
    func finish() { finished = true }
    /// Suspends until the stubbed request has started.
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    /// Holds the stubbed request open until the test releases it.
    func holdUntilReleased() async {
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }
    func release() {
        released = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll()
    }
}
